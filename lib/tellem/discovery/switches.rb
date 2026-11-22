# frozen_string_literal: true

require_relative "capabilities"
require_relative "records"
require_relative "settings"
require_relative "toml"

module Tellem
  module Discovery
    module Switches
      SENSITIVE = /header|token|secret|key|auth|password|credential/i.freeze
      OTEL_CLAUDE = /\A(?:CLAUDE_CODE_ENABLE_TELEMETRY|OTEL_.+)\z/.freeze
      SCOPE_RANK = { "managed" => 0, "project" => 2, "user" => 1 }.freeze

      module_function

      def capabilities(ctx, _deadline)
        Capabilities::ENTRIES.map do |entry|
          harness = ctx.harness(entry[:harness])
          resolved = Capabilities.resolve(entry, harness, ctx.scan(entry[:harness]))
          facts = { "name" => entry[:name], "form" => entry[:form], "version" => harness["version"], "note" => resolved["note"] }
          facts["effective"] = effective_expiry(ctx, entry) if entry[:kind] == "expiry"
          Records.item(id: "#{entry[:kind]}:#{entry[:harness]}:#{entry[:name]}", kind: entry[:kind], harness: entry[:harness],
                       state: resolved["state"], known_by: resolved["known_by"], facts: facts, reason: resolved["state"] == "unknown" ? resolved["note"] : nil)
        end
      end

      def effective_expiry(ctx, entry)
        values = occurrences(ctx, entry).sort_by { |found| SCOPE_RANK.fetch(found["scope"], 3) }
        return { "value" => values.first["value"], "source" => values.first["path"] } unless values.empty?

        { "value" => entry[:table]["default"], "source" => "default", "minimum" => entry[:table]["minimum"] }
      end

      def controls(ctx, _deadline)
        Capabilities::ENTRIES.map do |entry|
          harness = ctx.harness(entry[:harness])
          resolved = Capabilities.resolve(entry, harness, ctx.scan(entry[:harness]))
          found = occurrences(ctx, entry)
          {
            "id" => "control:#{entry[:harness]}:#{entry[:name]}", "harness" => entry[:harness], "name" => entry[:name],
            "kind" => entry[:kind], "form" => entry[:form], "capability" => resolved["state"], "known_by" => resolved["known_by"],
            "settings" => found, "effective" => found.empty? ? nil : found.min_by { |item| SCOPE_RANK.fetch(item["scope"], 3) }["value"]
          }.compact
        end
      end

      def occurrences(ctx, entry)
        if entry[:harness] == "claude"
          claude_occurrences(ctx, entry)
        elsif entry[:name] == "history.persistence"
          codex_history(ctx)
        else
          []
        end
      end

      def claude_occurrences(ctx, entry)
        if entry[:form] == "env"
          Settings.claude_env(ctx.claude_files).select { |item| item["key"] == entry[:name] }
                  .map { |item| { "scope" => item["scope"], "path" => item["path"], "value" => item["value"].to_s } }
        elsif entry[:form] == "setting"
          ctx.claude_files.filter_map do |file|
            { "scope" => file["scope"], "path" => file["path"], "value" => file["data"][entry[:name]] } if file["data"].key?(entry[:name])
          end
        else
          []
        end
      end

      def codex_history(ctx)
        return [] unless ctx.codex_config

        Toml.table(ctx.codex_config, ["history"]).select { |item| item[:key] == "persistence" && item[:section] == ["history"] }
            .map { |item| { "scope" => "user", "path" => File.join(ctx.paths[:codex_home], "config.toml"), "value" => item[:value].to_s } }
      end

      def otel(ctx, _deadline)
        [claude_otel(ctx), codex_otel(ctx)]
      end

      def claude_otel(ctx)
        keys = Settings.claude_env(ctx.claude_files).select { |item| OTEL_CLAUDE.match?(item["key"]) }
        facts = keys.to_h { |item| [item["key"], shown(item["key"], item["value"])] }.sort.to_h
        Records.item(id: "otel:claude", kind: "otel", harness: "claude", state: keys.empty? ? "absent" : "present", known_by: "table", facts: facts)
      end

      def codex_otel(ctx)
        found = ctx.codex_config ? Toml.table(ctx.codex_config, ["otel"]) : []
        facts = found.to_h do |item|
          name = (item[:section].drop(1) + [item[:key]]).join(".")
          [name, item[:value] == :complex ? "[complex]" : shown(name, item[:value])]
        end
        Records.item(id: "otel:codex", kind: "otel", harness: "codex", state: found.empty? ? "absent" : "present", known_by: "table", facts: facts.sort.to_h)
      end

      def shown(name, value)
        return "[hidden]" if SENSITIVE.match?(name.to_s)

        value.is_a?(String) ? value.sub(%r{//[^/@\s]*@}, "//") : value
      end
    end
  end
end
