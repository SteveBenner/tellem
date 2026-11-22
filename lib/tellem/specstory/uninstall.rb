# frozen_string_literal: true

require_relative "../ports/harness_paths"

module Tellem
  module Specstory
    module Uninstall
      PROGRAM = "specstory"

      module_function

      def find(path_value)
        path_value.split(":").reject(&:empty?).each do |dir|
          candidate = File.join(dir, PROGRAM)
          return candidate if File.file?(candidate) && File.executable?(candidate)
        end
        nil
      end

      def describe(path_value)
        found = find(path_value)
        return { "found" => false, "command" => nil, "method" => "none" } unless found

        real = begin
          File.realpath(found)
        rescue SystemCallError
          found
        end
        method, command = classify(found, real)
        { "found" => true, "path" => found, "real_path" => real, "method" => method, "command" => command }
      end

      def classify(path, real)
        case real
        when %r{/Cellar/#{PROGRAM}/}, %r{/linuxbrew/}, %r{/homebrew/} then ["homebrew", "brew uninstall #{PROGRAM}"]
        when %r{/node_modules/} then ["npm", "npm uninstall -g #{npm_package(real)}"]
        when %r{/go/bin/} then ["go", "rm #{shell(path)}"]
        when %r{\A/usr/(?:local/)?s?bin/}, %r{\A/s?bin/} then ["system", "remove it with the package manager that owns #{shell(real)} (for example dpkg -S #{shell(real)} names the package)"]
        else ["manual", "rm #{shell(path)}"]
        end
      end

      def npm_package(real)
        tail = real.split("/node_modules/").last.to_s.split("/")
        tail.first.to_s.start_with?("@") ? tail.first(2).join("/") : tail.first.to_s
      end

      def shell(word)
        word.match?(%r{\A[A-Za-z0-9_./:=@+-]+\z}) ? word : "'#{word.gsub("'", "'\\\\''")}'"
      end
    end
  end
end
