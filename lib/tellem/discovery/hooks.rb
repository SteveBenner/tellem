# frozen_string_literal: true

require "json"
require_relative "../cutover/discover"
require_relative "../ports/harness_paths"
require_relative "bounds"
require_relative "plugins"
require_relative "records"
require_relative "settings"
require_relative "toml"

module Tellem
  module Discovery
    module Hooks
      PLUGIN = Ports::HarnessPaths::PLUGIN_ID
      LEVELS = %w[claude codex].freeze

      module_function

      def hooks(ctx, _deadline)
        claude_hooks(ctx) + codex_hooks(ctx) + incumbent_hooks(ctx)
      end

      def claude_hooks(ctx)
        ctx.claude_files.flat_map do |file|
          Cutover::Discover.entries(file["data"]).map do |event, command|
            Records.item(id: "hook:claude:#{file['scope']}:#{event}:#{Records.short("#{file['path']}\0#{command}")}", kind: "hook", harness: "claude",
                         known_by: "table", facts: { "event" => event, "command" => Records.clean(command), "path" => file["path"], "scope" => file["scope"] })
          end
        end
      end

      def codex_hooks(ctx)
        return [] unless ctx.codex_config

        path = File.join(ctx.paths[:codex_home], "config.toml")
        ctx.codex_config.filter_map do |entry|
          next unless entry[:key] == "command" && entry[:section].first == "hooks" && entry[:section].last == "hooks" && entry[:value].is_a?(String)

          event = entry[:section][1]
          Records.item(id: "hook:codex:#{event}:#{Records.short(entry[:value])}", kind: "hook", harness: "codex", known_by: "table",
                       facts: { "event" => event, "command" => Records.clean(entry[:value]), "path" => path, "scope" => "user" })
        end
      end

      def incumbent_hooks(ctx)
        ai_home = ctx.paths[:ai_home]
        return [] unless ai_home

        scripts = Cutover::Discover.hooks(ai_home)
        names = scripts.map { |hook| hook["name"] }
        registrations = Cutover::Discover.registrations(ai_home, names)
        registered = registrations.map { |entry| entry["hook"] }
        scripts.map do |hook|
          Records.item(id: "hook:incumbent:#{hook['path']}", kind: "hook", known_by: "table",
                       facts: { "path" => File.join(ai_home, hook["path"]), "captures" => hook["captures"], "registered" => registered.include?(hook["name"]) })
        end + registrations.map do |entry|
          Records.item(id: "hook:incumbent_registration:#{entry['file']}:#{entry['event']}:#{entry['hook']}", kind: "hook", known_by: "table",
                       facts: { "file" => entry["file"], "event" => entry["event"], "hook" => entry["hook"], "command" => Records.clean(entry["command"]) })
        end
      end

      def codex_trust(ctx, _deadline)
        state = trust_state(ctx)
        [
          Records.item(id: "codex_trust:state", kind: "codex_trust", harness: "codex", known_by: "table",
                       facts: { "entries" => state.size, "trusted" => state.count { |_key, info| info[:trusted] } }),
          tellem_trust(ctx, state)
        ]
      end

      def trust_state(ctx)
        return {} unless ctx.codex_config

        found = {}
        ctx.codex_config.each do |entry|
          next unless entry[:section].first(2) == %w[hooks state] && entry[:section].size >= 3

          key = entry[:section][2]
          info = (found[key] ||= { trusted: false, enabled: true })
          info[:trusted] = true if entry[:key] == "trusted_hash" && entry[:value].is_a?(String) && !entry[:value].empty?
          info[:enabled] = false if entry[:key] == "enabled" && entry[:value] == false
        end
        found
      end

      def tellem_trust(ctx, state)
        declared = declared_codex_hooks(ctx)
        trusted = state.count { |key, info| key.include?(PLUGIN) && info[:trusted] && info[:enabled] }
        verdict = if declared.zero? then "not_installed"
                  elsif trusted.zero? then "untrusted"
                  elsif trusted < declared then "partial"
                  else "trusted"
                  end
        Records.item(id: "codex_trust:#{PLUGIN}", kind: "codex_trust", harness: "codex", known_by: "table",
                     facts: { "declared_hooks" => declared, "trusted_keys" => trusted, "verdict" => verdict, "matched_by" => "state key naming the plugin id" })
      end

      def declared_codex_hooks(ctx)
        plugin = Plugins.tellem_codex(ctx.paths, PLUGIN).first
        return 0 unless plugin

        manifest = Settings.json(File.join(plugin["root"], ".codex-plugin", "plugin.json"))
        relative = manifest && manifest["hooks"]
        return 0 unless relative.is_a?(String)

        root = Bounds.real(plugin["root"])
        file = Bounds.real(File.expand_path(relative, plugin["root"]))
        return 0 unless root && file&.start_with?("#{root}/")

        count_commands(Settings.json(file))
      end

      def count_commands(node)
        case node
        when Hash then node.sum { |key, value| key == "command" && value.is_a?(String) ? 1 : count_commands(value) }
        when Array then node.sum { |value| count_commands(value) }
        else 0
        end
      end

      def tellem(ctx, _deadline)
        [level, claude_install(ctx)]
      end

      def level
        facts = { "cutover_state" => setting("cutover.state"), "retention_native" => setting("retention.native") }
        LEVELS.each { |harness| facts["authority_#{harness}"] = setting("authority.#{harness}") || "observe" }
        facts["reasoning"] = "unavailable at own: bodies redact it" if facts["authority_claude"] == "own"
        Records.item(id: "tellem:level", kind: "tellem", known_by: "table", facts: facts.merge("version" => Tellem::VERSION))
      end

      def setting(key)
        return nil unless Tellem::Config.keys.include?(key)

        Tellem::Config.get(key)
      rescue Tellem::Error, Rplugin::Error => e
        "unreadable: #{e.class.name.split('::').last}"
      end

      def claude_install(ctx)
        installed = Plugins.claude(ctx.paths).select { |plugin| Plugins.name_of(plugin["id"]) == PLUGIN }
        enabled = ctx.claude_files.any? do |file|
          plugins = file["data"]["enabledPlugins"]
          plugins.is_a?(Hash) && plugins.any? { |key, value| key.split("@").first == PLUGIN && value == true }
        end
        Records.item(id: "tellem:hooks:claude", kind: "tellem", harness: "claude", known_by: "table",
                     state: installed.empty? ? "absent" : "present",
                     facts: { "installed_versions" => installed.map { |plugin| plugin["version"] }.compact.sort, "enabled" => enabled })
      end
    end
  end
end
