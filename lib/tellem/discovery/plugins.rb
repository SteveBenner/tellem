# frozen_string_literal: true

require "json"
require_relative "bounds"
require_relative "settings"

module Tellem
  module Discovery
    module Plugins
      module_function

      def newest(dir)
        names = Bounds.children(dir).select { |name| Bounds.lstat(File.join(dir, name))&.directory? }
        names.max_by { |name| name.scan(/\d+/).map(&:to_i) + [name.length] }
      end

      def claude(paths)
        file = File.join(paths[:claude_home], "plugins", "installed_plugins.json")
        data = Settings.json(file)
        return [] unless data && data["plugins"].is_a?(Hash)

        data["plugins"].flat_map do |key, installs|
          Array(installs).filter_map do |install|
            next unless install.is_a?(Hash) && install["installPath"].is_a?(String)

            { "id" => plugin_id(key), "root" => install["installPath"], "source" => "claude_plugins", "version" => install["version"] }
          end
        end
      end

      def codex(paths)
        base = File.join(paths[:codex_home], "plugins", "cache")
        Bounds.children(base).flat_map do |market|
          Bounds.children(File.join(base, market)).filter_map do |plugin|
            dir = File.join(base, market, plugin)
            version = newest(dir)
            next unless version

            { "id" => plugin_id("#{plugin}@#{market}"), "root" => File.join(dir, version), "source" => "codex_plugins", "version" => version }
          end
        end
      end

      def registry(paths)
        base = paths[:plugins_home]
        return [] unless base

        Bounds.children(base).reject { |name| name.start_with?(".") }.filter_map do |name|
          dir = File.join(base, name)
          { "id" => name, "root" => dir, "source" => "rplugin_registry" } if Bounds.lstat(dir)&.directory? || Bounds.stat(dir)&.directory?
        end
      end

      def plugin_id(key)
        name, market = key.split("@", 2)
        market.nil? || market == name ? name : key
      end

      def name_of(id)
        id.split("@").first
      end

      def all(paths)
        claude(paths) + codex(paths) + registry(paths)
      end

      def tellem_codex(paths, plugin_id)
        codex(paths).select { |plugin| name_of(plugin["id"]) == plugin_id }
      end
    end
  end
end
