# frozen_string_literal: true

require "json"
require_relative "bounds"
require_relative "toml"

module Tellem
  module Discovery
    module Settings
      CLAUDE_NAMES = %w[settings.json settings.local.json].freeze

      module_function

      def claude_files(paths)
        found = []
        seen = {}
        candidates = CLAUDE_NAMES.map { |name| ["user", File.join(paths[:claude_home], name)] }
        candidates << ["managed", paths[:managed_settings]] if paths[:managed_settings]
        Array(paths[:scopes]).each do |root|
          CLAUDE_NAMES.each { |name| candidates << ["project", File.join(root, ".claude", name)] }
        end
        candidates.each do |scope, path|
          real = Bounds.real(path)
          next if real.nil? || seen[real]

          seen[real] = true
          data = json(path)
          found << { "scope" => scope, "path" => path, "real" => real, "data" => data } if data
        end
        found
      end

      def json(path)
        text = Bounds.text(path)
        return nil unless text

        data = JSON.parse(text)
        data.is_a?(Hash) ? data : nil
      rescue JSON::ParserError
        nil
      end

      def codex_config(paths)
        path = File.join(paths[:codex_home], "config.toml")
        text = Bounds.text(path)
        text ? Toml.entries(text) : nil
      end

      def claude_env(files)
        files.flat_map do |file|
          env = file["data"]["env"]
          next [] unless env.is_a?(Hash)

          env.map { |key, value| { "key" => key, "value" => value, "scope" => file["scope"], "path" => file["path"] } }
        end
      end
    end
  end
end
