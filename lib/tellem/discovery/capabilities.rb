# frozen_string_literal: true

module Tellem
  module Discovery
    module Capabilities
      ENTRIES = [
        { harness: "claude", kind: "expiry", name: "cleanupPeriodDays", form: "setting", needle: "cleanupPeriodDays", table: { "default" => 30, "minimum" => 1 } },
        { harness: "claude", kind: "switch", name: "CLAUDE_CODE_SKIP_PROMPT_HISTORY", form: "env", needle: "CLAUDE_CODE_SKIP_PROMPT_HISTORY" },
        { harness: "claude", kind: "switch", name: "--no-session-persistence", form: "flag", needle: "--no-session-persistence" },
        { harness: "claude", kind: "switch", name: "OTEL_LOG_RAW_API_BODIES", form: "env", needle: "OTEL_LOG_RAW_API_BODIES" },
        { harness: "codex", kind: "switch", name: "exec --ephemeral", form: "flag", needle: "--ephemeral" },
        { harness: "codex", kind: "switch", name: "history.persistence", form: "setting", needle: "HistoryPersistence" },
        { harness: "codex", kind: "switch", name: "delete", form: "command", needle: "codex delete" }
      ].freeze

      FEATURES = [
        { harness: "claude", name: "resume", needle: "--resume" },
        { harness: "claude", name: "continue", needle: "--continue" },
        { harness: "claude", name: "fork", needle: "--fork-session" },
        { harness: "claude", name: "rewind", needle: "rewind" },
        { harness: "claude", name: "logs", needle: "claude logs" },
        { harness: "claude", name: "attach", needle: "claude attach" },
        { harness: "claude", name: "respawn", needle: "respawn" },
        { harness: "codex", name: "resume", needle: "resume" }
      ].freeze

      EVIDENCE = {
        ["claude", "2.1.318", "CLAUDE_CODE_SKIP_PROMPT_HISTORY"] => "a recorded session left no native transcript file, in print mode and interactive",
        ["claude", "2.1.318", "OTEL_LOG_RAW_API_BODIES"] => "a recorded session wrote request and response body files",
        ["claude", "2.1.318", "cleanupPeriodDays"] => "a recorded session with the value 1 kept its transcript"
      }.freeze

      module_function

      def entries(harness)
        ENTRIES.select { |entry| entry[:harness] == harness }
      end

      def features(harness)
        FEATURES.select { |entry| entry[:harness] == harness }
      end

      def needles(harness)
        (entries(harness) + features(harness)).map { |entry| entry[:needle] }.uniq
      end

      def resolve(entry, harness, scan)
        needle = entry[:needle]
        evidence = EVIDENCE[[harness["id"], harness["version"], entry[:name]]]
        if scan[:reason]
          return { "state" => "present", "known_by" => "evidence", "note" => evidence } if evidence
          return { "state" => "present", "known_by" => "table", "note" => entry[:table].to_a.join("=") } if entry[:table]

          return { "state" => "unknown", "known_by" => "unknown", "note" => scan[:reason] }
        end
        return { "state" => "present", "known_by" => "binary", "note" => nil } if scan[:found][needle]
        return { "state" => "present", "known_by" => "evidence", "note" => evidence } if evidence

        { "state" => "absent", "known_by" => "binary", "note" => "not in the installed binary at version #{harness['version'] || 'unknown'}" }
      end
    end
  end
end
