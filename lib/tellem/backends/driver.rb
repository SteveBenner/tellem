# frozen_string_literal: true

require_relative "../errors"

module Tellem
  module Backends
    module Driver
      GEMS = {
        "sqlite" => { name: "sqlite3", requirement: "~> 2.0", library: "sqlite3" },
        "postgres" => { name: "pg", requirement: "~> 1.5", library: "pg" }
      }.freeze

      module_function

      def spec(kind)
        GEMS.fetch(kind.to_s) { raise UsageError.new("unknown backend #{kind}; known: #{GEMS.keys.join(', ')}") }
      end

      def install_command(kind)
        gem = spec(kind)
        "gem install --user-install #{gem[:name]} -v '#{gem[:requirement]}'"
      end

      def available?(kind)
        gem = spec(kind)
        refresh
        !Gem::Specification.find_all_by_name(gem[:name], gem[:requirement]).empty?
      rescue Gem::LoadError
        false
      end

      def load!(kind)
        gem = spec(kind)
        raise missing(kind) unless available?(kind)

        Kernel.send(:gem, gem[:name], gem[:requirement])
        require gem[:library]
        true
      rescue LoadError => e
        raise missing(kind, "the #{gem[:name]} driver did not load (#{e.class})")
      end

      def ensure!(kind, install:, err: $stderr)
        return load!(kind) if available?(kind)
        raise missing(kind) unless install

        install!(kind, err: err)
        load!(kind)
      end

      def install!(kind, err: $stderr)
        gem = spec(kind)
        runner = "require 'rubygems'; require 'rubygems/gem_runner'; Gem::GemRunner.new.run(ARGV)"
        argv = [Gem.ruby, "-e", runner, "--", "install", gem[:name], "-v", gem[:requirement], "--no-document", *destination]
        ok = system(*argv, in: File::NULL, out: err, err: err)
        unless ok
          raise CapabilityUnavailable.new(
            "installing the #{gem[:name]} driver failed; a native build may need development headers " \
            "(sqlite3: libsqlite3-dev, pg: libpq-dev)",
            next_command: install_command(kind)
          )
        end
        refresh
        true
      end

      def destination
        home = ENV["GEM_HOME"]
        home && !home.empty? ? ["--install-dir", home] : ["--user-install"]
      end

      def refresh
        Gem.clear_paths
        Gem::Specification.reset
      end

      def missing(kind, reason = nil)
        command = install_command(kind)
        CapabilityUnavailable.new(
          "#{reason || "the #{spec(kind)[:name]} driver gem is not installed"}; install it with `#{command}` " \
          "or rerun with --install-driver",
          next_command: command
        )
      end
    end
  end
end
