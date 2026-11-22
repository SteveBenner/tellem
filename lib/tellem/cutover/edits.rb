# frozen_string_literal: true

require "digest"
require "json"

module Tellem
  module Cutover
    module Edits
      NEW_RULES = { "subagent-specstory" => "every subagent transcript is recorded by tellem beside its parent's session" }.freeze
      ENFORCE = "capture:tellem"
      REASON = "retired by tellem cutover; tellem captures transcripts and tokens"
      FRONTMATTER_KEY = /\A(rule|enforce): (.*)\z/

      module_function

      def stem(name)
        name.sub(/\.[A-Za-z0-9]+\z/, "")
      end

      def registrations(bytes, hook_names)
        data = JSON.parse(bytes)
        removed = []
        hooks = data["hooks"]
        return [bytes, removed] unless hooks.is_a?(Hash)

        hooks.each_key.to_a.each do |event|
          groups = Array(hooks[event]).filter_map do |group|
            next group unless group.is_a?(Hash) && group["hooks"].is_a?(Array)

            kept = group["hooks"].reject do |hook|
              command = hook.is_a?(Hash) ? hook["command"] : nil
              name = command.is_a?(String) && hook_names.find { |hook_name| command_names?(command, hook_name) }
              removed << "remove #{event} hook #{name}" if name
              name
            end
            next nil if kept.empty?

            group.merge("hooks" => kept)
          end
          groups.empty? ? hooks.delete(event) : hooks[event] = groups
        end
        [json(data, bytes), removed]
      end

      def command_names?(command, name)
        command.split(/\s+/).any? { |word| File.basename(word.delete("\"'")) == name }
      end

      def unregistered(bytes, hook_names)
        text = bytes.to_s.dup
        listed = text.each_line.map { |line| line.split(/\s+/).first }
        added = hook_names.reject { |name| listed.include?(name) }
        return [bytes, []] if added.empty?

        text << "\n" unless text.empty? || text.end_with?("\n")
        added.each { |name| text << "#{name}  #{REASON}\n" }
        [text, added.map { |name| "list #{name} as unregistered by design" }]
      end

      def directive(bytes, stem)
        replacement = NEW_RULES[stem]
        return [bytes, [], nil] unless replacement

        lines = bytes.lines
        fences = lines.each_index.select { |index| lines[index].chomp == "---" }.first(2)
        return [bytes, [], nil] unless fences.size == 2 && fences.first.zero?

        old_rule = nil
        changes = []
        (fences[0] + 1...fences[1]).each do |index|
          match = FRONTMATTER_KEY.match(lines[index].chomp)
          next unless match

          if match[1] == "enforce" && match[2] == "capture:#{stem}"
            lines[index] = "enforce: #{ENFORCE}\n"
            changes << "enforce capture:#{stem} -> #{ENFORCE}"
          elsif match[1] == "rule"
            old_rule = match[2]
          end
        end
        return [bytes, [], nil] if changes.empty? || old_rule.nil?

        rule_index = (fences[0] + 1...fences[1]).find { |index| lines[index].start_with?("rule: ") }
        lines[rule_index] = "rule: #{replacement}\n"
        changes << "rule names tellem"
        [lines.join, changes, old_rule]
      end

      def agents_rows(bytes, stem, old_rule)
        replacement = NEW_RULES[stem]
        target = "capture:#{stem}"
        changes = []
        lines = bytes.lines.map do |line|
          next line unless line.include?(target) && line.include?(old_rule)

          changes << "row #{target} names tellem"
          keep_width(keep_width(line, old_rule, replacement), target, ENFORCE)
        end
        [lines.join, changes]
      end

      def keep_width(line, old, new)
        start = line.index(old)
        return line unless start

        rest = line[(start + old.length)..]
        spaces = rest[/\A */].length
        after = rest[spaces..]
        return "#{line[0, start]}#{new}#{rest}" if after.chomp.empty?

        padding = [spaces + old.length - new.length, 1].max
        "#{line[0, start]}#{new}#{' ' * padding}#{after}"
      end

      def otel_env(port, token)
        {
          "CLAUDE_CODE_ENABLE_TELEMETRY" => "1",
          "OTEL_LOGS_EXPORTER" => "otlp",
          "OTEL_EXPORTER_OTLP_PROTOCOL" => "http/json",
          "OTEL_EXPORTER_OTLP_LOGS_ENDPOINT" => "http://127.0.0.1:#{port}/v1/logs",
          "OTEL_EXPORTER_OTLP_HEADERS" => "Authorization=Bearer #{token}",
          "OTEL_METRICS_EXPORTER" => "none",
          "OTEL_TRACES_EXPORTER" => "none"
        }
      end

      def claude_env(bytes, env)
        data = bytes.to_s.strip.empty? ? {} : JSON.parse(bytes)
        current = data["env"].is_a?(Hash) ? data["env"] : {}
        changed = env.keys.reject { |key| current[key] == env[key] }
        return [bytes, []] if changed.empty?

        data["env"] = current.merge(env)
        [json(data, bytes), changed.map { |key| "env #{key}" }]
      end

      def env_conflicts(bytes, env)
        current = current_env(bytes)
        env.keys.select { |key| current.key?(key) && current[key] != env[key] }
      end

      def env_added(bytes, env)
        current = current_env(bytes)
        env.keys.reject { |key| current[key] == env[key] }
      end

      def env_digests(env, keys)
        keys.to_h { |key| [key, Digest::SHA256.hexdigest(env.fetch(key).to_s)] }
      end

      def remove_env(bytes, digests)
        data = bytes.to_s.strip.empty? ? {} : JSON.parse(bytes)
        current = data["env"].is_a?(Hash) ? data["env"] : {}
        gone = digests.keys.select { |key| current.key?(key) && Digest::SHA256.hexdigest(current[key].to_s) == digests[key] }
        kept = digests.keys.select { |key| current.key?(key) } - gone
        return [bytes, [], kept] if gone.empty?

        left = current.reject { |key, _| gone.include?(key) }
        left.empty? ? data.delete("env") : data["env"] = left
        [json(data, bytes), gone, kept]
      end

      def current_env(bytes)
        data = bytes.to_s.strip.empty? ? {} : JSON.parse(bytes)
        data["env"].is_a?(Hash) ? data["env"] : {}
      end

      def json(data, original)
        text = JSON.pretty_generate(data)
        original.to_s.end_with?("\n") || original.to_s.empty? ? "#{text}\n" : text
      end
    end
  end
end
