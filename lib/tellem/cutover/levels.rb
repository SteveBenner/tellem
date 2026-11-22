# frozen_string_literal: true

require_relative "../authority/ledger"
require_relative "../authority/state"
require_relative "../authority/switch"
require_relative "../errors"
require_relative "../parity/report"
require_relative "../reports/refresh"
require_relative "../reports/scopes"

module Tellem
  module Cutover
    module Levels
      CLAUDE = %w[observe spool rehearse own].freeze
      CODEX = %w[observe spool].freeze
      SPECSTORY = %w[coexist subsume].freeze
      RAISING = %w[spool own].freeze
      WITH_ENV = %w[rehearse own].freeze
      OWN_SWITCHES = %w[CLAUDE_CODE_SKIP_PROMPT_HISTORY OTEL_LOG_RAW_API_BODIES].freeze
      REHEARSE_SWITCHES = %w[OTEL_LOG_RAW_API_BODIES].freeze
      SKIP_KEY = "CLAUDE_CODE_SKIP_PROMPT_HISTORY"
      BODIES_KEY = "OTEL_LOG_RAW_API_BODIES"
      NEXT = "tellem cutover plan"
      COSTS = {
        "observe" => "native transcripts stay; no reader is affected; disk use is unchanged",
        "spool" => "native files leave the disk once their record is verified, so harness resume, rewind, and logs lose each removed session",
        "rehearse" => "native stays on and the file mode is on too, so nothing is withheld from any reader; disk use rises until each session is compared; it frees no disk",
        "own" => "Claude Code writes no native transcript, so resume, rewind, and logs have nothing to open and it warns that transcript saving is off; " \
                 "reasoning text is unavailable; the session that reveals a loss cannot be recovered"
      }.freeze
      LOSES = {
        "terminal_tool_result_not_in_bodies" => "a subagent's last tool result, such as SubagentHandback's, is not recorded",
        "native_only_request" => "an interrupted stream's message id and usage are not recorded, so its tokens go uncounted",
        "timestamps_differ" => "turn times come from the send and the response's end, not from each block's arrival; the cause is untraced",
        "native_only_trailing_turns" => "a task notification queued as the session exits is not recorded",
        "exchange_source_differs" => "text the harness injects in a new form reads as a user prompt",
        "tool_input_enriched_after_the_wire" => "tool input keys the harness adds after sending are not recorded",
        "reasoning_text_only_in_native" => "visible reasoning text is not recorded",
        "body_unattributed" => "a subagent interrupted on its first request is not attributed, and its request stays in the spool with a gap"
      }.freeze

      module_function

      def request(raw)
        given = (raw || {}).transform_keys(&:to_s)
        { "claude" => given["claude"], "codex" => given["codex"], "specstory" => given["specstory"], "purge" => given["purge"] == true,
          "accept_readers" => Array(given["accept_readers"]).uniq.sort, "accept_parity" => Array(given["accept_parity"]).uniq.sort,
          "link_targets" => Array(given["link_targets"]).uniq.sort }
      end

      def empty?(request)
        request["claude"].nil? && request["codex"].nil? && request["specstory"].nil? && !request["purge"]
      end

      def raising(request)
        { "claude" => request["claude"], "codex" => request["codex"] }.select { |_name, level| RAISING.include?(level) }.keys
      end

      def validate!(request)
        refuse("level_not_available", "--codex #{request['codex']}: Codex reaches spool at most; interactive Codex offers no switch that stops rollouts") if request["codex"] == "own" || request["codex"] == "rehearse"
        unknown(request["claude"], CLAUDE, "--claude")
        unknown(request["codex"], CODEX, "--codex")
        unknown(request["specstory"], SPECSTORY, "--specstory")
        raise UsageError.new("--purge needs --claude spool or own, or --codex spool", next_command: NEXT) if request["purge"] && raising(request).empty?
        raise UsageError.new("--accept-parity applies only to --claude own", next_command: NEXT) if !request["accept_parity"].empty? && request["claude"] != "own"

        request["link_targets"].each do |path|
          raise UsageError.new("--link-target needs an absolute path, not #{path}", next_command: NEXT) unless path.start_with?("/")
        end
      end

      def unknown(value, allowed, flag)
        return if value.nil? || allowed.include?(value)

        raise UsageError.new("#{flag} must be one of #{allowed.join(', ')}, not #{value}", next_command: NEXT)
      end

      def check!(request, report)
        stopped = Authority::Switch.reason
        if stopped && (!raising(request).empty? || WITH_ENV.include?(request["claude"]))
          refuse("authority_stopped", "the authority stop switch is set (#{stopped}); clear it with tellem authority resume before raising a level", next_command: "tellem authority resume")
        end
        required = required_readers(request, report)
        if request["claude"] == "own"
          own!(request, report, required)
        else
          switches!(report, REHEARSE_SWITCHES) if request["claude"] == "rehearse"
          readers!(request, required)
        end
        gate!(request)
      end

      def gate!(request)
        raised = raising(request)
        return if raised.empty?

        scopes = Reports::Scopes.resolve(all: true)
        Reports::Refresh.run(scopes)
        criteria = Tellem::Parity.run(scopes)["criteria"]
        raised.each do |name|
          group = criteria[name]
          next if group["met"]

          refuse("parity_unmet", "#{name} parity is #{group['passing']}/#{group['required']} of the last #{group['required']} shadowed sessions; " \
                                 "#{request[name]} removes native transcripts, so it needs the full count",
                 next_command: "tellem parity --all", detail: group)
        end
      end

      def own!(request, report, required)
        switches!(report, OWN_SWITCHES)
        parity!(request, claude_version(report))
        readers!(request, required)
        specstory!(request, report)
      end

      def switches!(report, names)
        records = report["methods"].select { |entry| entry["kind"] == "switch" && entry["harness"] == "claude" }
        names.each do |name|
          record = records.find { |entry| entry.dig("facts", "name") == name }
          state = record ? record["state"] : "unknown"
          next if state == "present"

          note = record&.dig("facts", "note") || record&.fetch("reason", nil)
          refuse("switch_absent", "own and rehearse need #{name}, which reads #{state} at Claude Code #{claude_version(report) || 'unknown'}#{note ? " (#{note})" : ''}",
                 detail: { "switch" => name, "state" => state, "version" => claude_version(report) })
        end
      end

      def claude_version(report)
        report["harnesses"].find { |harness| harness["id"] == "claude" }&.fetch("version", nil)
      end

      def parity!(request, version)
        invented = request["accept_parity"] - LOSES.keys
        unless invented.empty?
          refuse("unknown_parity_cause", "--accept-parity names no known cause: #{invented.join(', ')}; known causes are #{LOSES.keys.join(', ')}",
                 detail: { "unknown" => invented })
        end
        rows = Authority::Ledger.at(version)
        if rows.empty?
          refuse("body_parity_unrecorded", "no body parity is recorded at Claude Code #{version || 'unknown'}" \
                                           "#{Authority::Ledger.versions.empty? ? '' : "; recorded versions: #{Authority::Ledger.versions.join(', ')}"}; run a rehearse plan on this version first",
                 next_command: "tellem cutover plan --claude rehearse --specstory coexist", detail: { "version" => version, "recorded_versions" => Authority::Ledger.versions })
        end
        found = Authority::Ledger.causes(version)
        unnamed = found - request["accept_parity"]
        unless unnamed.empty?
          refuse("body_parity_unmet", "body parity is unmet at Claude Code #{version}, with differences the plan does not name: #{unnamed.join(', ')}",
                 next_command: "tellem parity bodies", detail: { "version" => version, "unnamed" => unnamed, "sessions" => rows.size })
        end
        unseen = request["accept_parity"] - found
        return if unseen.empty?

        refuse("parity_cause_not_observed", "--accept-parity names causes not recorded at Claude Code #{version}: #{unseen.join(', ')}", detail: { "version" => version, "unseen" => unseen })
      end

      def required_readers(request, report)
        raised = raising(request)
        return [] if raised.empty?

        report["readers"].select do |reader|
          next raised.include?(reader["id"].split(":")[1]) if reader["kind"] == "harness_feature"

          reader["confidence"] != "none"
        end
      end

      def readers!(request, required)
        unnamed = required.map { |reader| reader["id"] } - request["accept_readers"]
        return if unnamed.empty?

        refuse("reader_not_accepted", "readers of native transcripts not named by --accept-reader: #{unnamed.join(', ')}", detail: { "unaccepted" => unnamed })
      end

      def specstory!(request, report)
        retired = request["specstory"] == "subsume" ? %w[wrapper hook] : []
        active = report["methods"].select do |entry|
          next false unless entry["state"] == "present"

          if Discovery::ACTIVE_KINDS.include?(entry["kind"]) then !retired.include?(entry["kind"])
          elsif entry["kind"] == "hook" then Array(entry.dig("facts", "captures")).include?("specstory_sync") && !retired.include?("hook")
          else false
          end
        end
        return if active.empty?

        refuse("specstory_active", "own refuses an active SpecStory: #{active.map { |entry| entry['id'] }.join(', ')}", detail: { "active" => active.map { |entry| entry["id"] } })
      end

      def refuse(cause, message, next_command: NEXT, detail: {})
        raise CapabilityUnavailable.new(message, next_command: next_command, detail: detail.merge("cause" => cause))
      end

      def env(level, otel, spool)
        return {} unless WITH_ENV.include?(level)

        found = otel.merge(BODIES_KEY => "file:#{spool}")
        level == "own" ? found.merge(SKIP_KEY => "1") : found
      end

      def text(plan)
        lines = []
        levels = plan["levels"] || {}
        levels.each { |name, level| lines << "  #{name} level #{level}: #{COSTS.fetch(level, '')}" }
        reported = Array(plan["readers"])
        unless reported.empty?
          lines << "  readers of native transcripts affected:"
          reported.each { |reader| lines << "    #{reader['id']} (#{reader['kind']}, #{reader['confidence']})#{reader['accepted'] ? ', accepted' : ''}" }
        end
        Array(plan["accepted_parity"]).each { |item| lines << "  accepted parity difference #{item['name']} at #{item['version']}: #{item['loses']}" }
        freed = plan["freed"]
        lines << "  frees #{freed['bytes']} bytes in #{freed['sessions']} sessions at most; the record keeps #{freed['record_bytes']} bytes, #{freed['share']} of them#{held_text(freed)}" if freed
        Array(plan["notes"]).each { |note| lines << "  note: #{note}" }
        lines
      end

      def held_text(freed)
        freed["unreadable"].to_i.positive? ? "; #{freed['unreadable']} rollouts tellem cannot read stay held" : ""
      end
    end
  end
end
