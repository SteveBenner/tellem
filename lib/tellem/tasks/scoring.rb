# frozen_string_literal: true

require_relative "text"

module Tellem
  module Tasks
    module Scoring
      GIT_PREFIX = /(?:\A|[;&|(\s])git(?:\s+-C\s+\S+|\s+-c\s+\S+|\s+--[\w-]+(?:=\S+)?)*\s+/
      GIT_COMMIT = /#{GIT_PREFIX}commit\b/
      GIT_PUSH = /#{GIT_PREFIX}push\b/
      WIP_LINE = /^(?:- |## )/
      EDIT_TOOLS = %w[Edit Write MultiEdit NotebookEdit].freeze
      WIP_EDIT_TOOLS = %w[Edit Write MultiEdit].freeze
      WIP_FILE = "WIP.md"

      module_function

      def pyround(value, digits)
        value.to_f.round(digits, half: :even)
      end

      def score(rules, idle, closing, repo_changed, cleared, overlap, words, first, question, token_count)
        steps = rules["idle_points"].map { |pair| [pair[0], pair[1]] }.sort.select { |minutes, _| minutes <= idle }
        idle_points = steps.empty? ? 0 : steps.last[1]
        counted = !overlap.nil? && token_count >= rules["overlap_min_tokens"]
        shown = overlap.nil? ? nil : pyround(overlap, 3)
        features = {
          "idle_minutes" => { "value" => pyround(idle, 1), "points" => idle_points },
          "closing" => { "value" => closing.dup, "points" => closing.empty? ? 0 : rules["closing_points"] },
          "repo_changed" => { "value" => repo_changed ? true : false, "points" => repo_changed ? rules["repo_points"] : 0 },
          "cleared" => { "value" => cleared ? true : false, "points" => cleared ? rules["clear_points"] : 0 },
          "overlap_low" => { "value" => shown, "points" => counted && overlap < rules["overlap_low"] ? rules["overlap_low_points"] : 0 },
          "overlap_high" => { "value" => shown, "points" => counted && overlap >= rules["overlap_high"] ? rules["overlap_high_points"] : 0 },
          "tokens" => { "value" => token_count, "points" => 0 },
          "continuation" => {
            "value" => { "words" => words, "first" => first },
            "points" => words <= rules["continuation_max_words"] || rules["continuation_openers"].include?(first) ? rules["continuation_points"] : 0
          },
          "question" => { "value" => question ? true : false, "points" => question ? rules["question_points"] : 0 }
        }
        [features.values.sum { |item| item["points"] }, features]
      end

      def wip_count(text)
        text.scan(WIP_LINE).length
      end

      def closing_hints(task, payload, reader)
        name = payload["tool_name"]
        data = payload["tool_input"] || {}
        hints = []
        if name == "Bash"
          command = Text.str(data["command"])
          hints << "commit" if GIT_COMMIT.match?(command)
          hints << "push" if GIT_PUSH.match?(command)
        elsif name == "Skill"
          hints << "checkpoint" if (data["skill"] || data["name"]) == "checkpoint"
        elsif WIP_EDIT_TOOLS.include?(name)
          wip_hint(task, name, data, reader, hints)
        end
        hints
      end

      def wip_hint(task, name, data, reader, hints)
        path = Text.str(data["file_path"])
        return unless Text.basename(path) == WIP_FILE && reader

        text = reader.call(path)
        return if text.nil?

        count = wip_count(text)
        prev = task["wip_counts"][path]
        if prev.nil? && name == "Edit"
          prev = count - (wip_count(Text.str(data["new_string"])) - wip_count(Text.str(data["old_string"])))
        end
        hints << "wip_removed" if !prev.nil? && count < prev
        task["wip_counts"][path] = count
      end

      def touched_tokens(payload)
        data = payload["tool_input"] || {}
        path = Text.str(data["file_path"]).then { |value| value.empty? ? Text.str(data["notebook_path"]) : value }
        return [] if path.empty?

        base = Text.basename(path)
        Text.tokens("#{Text.basename(Text.dirname(path))} #{base} #{Text.stem(base)}")
      end
    end
  end
end
