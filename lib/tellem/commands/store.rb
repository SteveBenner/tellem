# frozen_string_literal: true

require_relative "../backends/selector"
require_relative "../config/resolver"
require_relative "../errors"
require_relative "../ports/harness_paths"
require_relative "../record/scope"
require_relative "../seams"

module Tellem
  module Commands
    module Store
      SUBCOMMANDS = %w[provision status rebuild drop].freeze
      KINDS = %w[sqlite postgres].freeze
      USAGE = "tellem store provision sqlite|postgres [--scope PATH | --user] [--install-driver] [--secret NAME]; " \
              "tellem store status|rebuild|drop [--scope PATH | --user] [--confirm ID]"

      module_function

      def run(context)
        options = parse(context.args)
        case options[:sub]
        when "provision" then provision(options, context)
        when "status" then status(options)
        when "rebuild" then rebuild(options)
        when "drop" then drop(options)
        end
      end

      def parse(args)
        list = args.dup
        sub = list.shift
        raise UsageError.new("store needs one of #{SUBCOMMANDS.join(', ')}: #{USAGE}") unless SUBCOMMANDS.include?(sub)

        options = { sub: sub, install_driver: false }
        options[:kind] = list.shift if sub == "provision"
        raise UsageError.new("store provision needs sqlite or postgres: #{USAGE}") if sub == "provision" && !KINDS.include?(options[:kind])

        until list.empty?
          flag = list.shift
          case flag
          when "--scope" then options[:scope] = value(list, flag)
          when "--user" then options[:user] = true
          when "--install-driver" then options[:install_driver] = true
          when "--secret" then options[:secret] = value(list, flag)
          when "--confirm" then options[:confirm] = value(list, flag)
          else raise UsageError.new("unknown store argument #{flag}: #{USAGE}")
          end
        end
        check(options)
        options
      end

      def value(list, flag)
        item = list.shift
        raise UsageError.new("#{flag} needs a value: #{USAGE}") if item.nil? || item.start_with?("--")

        item
      end

      def check(options)
        raise UsageError.new("--scope and --user exclude each other: #{USAGE}") if options[:scope] && options[:user]
        raise UsageError.new("--install-driver and --secret apply to provision only: #{USAGE}") if options[:sub] != "provision" && (options[:install_driver] || options[:secret])
        raise UsageError.new("--confirm applies to drop only: #{USAGE}") if options[:confirm] && options[:sub] != "drop"
        raise UsageError.new("--secret applies to postgres only: #{USAGE}") if options[:secret] && options[:kind] != "postgres"
        raise UsageError.new("--secret takes an SDK secret name, never a URL") if options[:secret]&.include?("://")
      end

      def root(options)
        return Ports::HarnessPaths.user_scope_root if options[:user]

        path = options[:scope] || Dir.pwd
        raise UsageError.new("scope path #{path} does not exist") unless File.exist?(path)

        Record::Scope.locate(path)
      end

      def selector
        impl = Seams.fetch(:backend)
        impl.is_a?(Backends::Selector) ? impl : Backends::Selector.new
      end

      def provision(options, context)
        scope_root = root(options)
        Record::Scope.prepare(scope_root)
        location = if options[:user] then "user"
                   elsif options[:scope] then "scope"
                   else Config.get("backend.location", scope: scope_root).to_s
                   end
        secret = options[:secret] || Config.get("backend.secret", scope: scope_root).to_s
        adapter = selector.build(kind: options[:kind], location: location, secret: secret, scope_root: scope_root)
        result = with_stderr(context) { adapter.provision(location: location, install_driver: options[:install_driver]) }
        persist(options, scope_root, location)
        data = result.merge(scope_root: scope_root)
        { data: data, text: "provisioned #{describe(data)}" }
      end

      def with_stderr(context)
        previous = $stdout
        $stdout = context.stderr
        yield
      ensure
        $stdout = previous
      end

      def persist(options, scope_root, location)
        values = { "backend.kind" => options[:kind], "backend.location" => location }
        values["backend.secret"] = options[:secret] if options[:secret]
        values.each do |key, value|
          if options[:user]
            Config.set(key, value)
          else
            Config.set(key, value, scope: scope_root)
          end
        end
      end

      def adapter_for(options)
        scope_root = root(options)
        adapter = selector.for(scope_root)
        if adapter.kind == "none"
          raise CapabilityUnavailable.new("no backend is configured for #{scope_root}",
                                          next_command: "tellem store provision sqlite|postgres")
        end
        [adapter, scope_root]
      end

      def status(options)
        scope_root = root(options)
        adapter = selector.for(scope_root)
        data = (defined?(Backends::Mirror) && adapter.is_a?(Backends::Mirror) ? adapter.status(count: true) : adapter.status).merge(scope_root: scope_root)
        { data: data, text: describe(data) }
      end

      def rebuild(options)
        adapter, scope_root = adapter_for(options)
        scopes = options[:user] && adapter.respond_to?(:known_roots) ? [scope_root, *adapter.known_roots] : [scope_root]
        data = adapter.rebuild(scopes: scopes).merge(scope_root: scope_root)
        lines = Array(data[:rebuilt]).map { |entry| "  #{entry[:root]}: #{entry[:applied]} applied, #{entry[:skipped]} skipped" }
        { data: data, text: (["rebuilt #{describe(data)}"] + lines).join("\n") }
      end

      def drop(options)
        adapter, scope_root = adapter_for(options)
        data = adapter.drop(confirm: options[:confirm]).merge(scope_root: scope_root)
        layer = Config.explain("backend.kind", scope: scope_root)[:layer]
        layer == "scope" ? Config.unset("backend.kind", scope: scope_root) : Config.unset("backend.kind")
        data[:backend_kind_after] = Config.get("backend.kind", scope: scope_root)
        { data: data, text: "dropped the #{data[:kind]} mirror at #{data[:location]}; backend.kind is now #{data[:backend_kind_after]}" }
      end

      def describe(data)
        parts = ["#{data[:kind]} mirror at #{data[:location] || 'nowhere'}"]
        unknown = data[:reachable] == false && data[:provisioned].nil?
        parts << "schema #{data[:schema_version] || (unknown ? 'unknown' : 'none')}"
        parts << "#{data[:rows] || (unknown ? 'unknown' : 0)} rows"
        parts << "lag #{data[:lag_seconds].nil? ? 'unknown' : "#{data[:lag_seconds]} s"}"
        parts << "last sync #{data[:last_sync_at] || 'never'}"
        parts << "reachable #{data[:reachable] ? 'yes' : 'no'}"
        parts << "breaker #{data[:breaker]}"
        parts << "disabled by TELLEM_BACKEND_DISABLED" if data[:disabled]
        parts << "error #{data[:error]}" if data[:error]
        parts.join(", ")
      end
    end
  end
end
