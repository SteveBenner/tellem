# frozen_string_literal: true

require_relative "../config/resolver"
require_relative "../errors"
require_relative "../ids"
require_relative "../record/fs"
require_relative "../record/scope"
require_relative "../deriver/context"
require_relative "../authority/state"
require_relative "../authority/switch"
require_relative "check"
require_relative "codex_rollouts"
require_relative "remove"

module Tellem
  module Retention
    KILL_SWITCH = "TELLEM_RETENTION_DISABLED"
    DEFAULT_DAYS = 14
    DAY_S = 86_400
    GAP = "retention_held"
    HARNESSES = %w[claude codex].freeze
    ZERO_LEVELS = %w[spool own].freeze

    module_function

    def gate(root, harness = "claude")
      return "authority_stopped" if Authority::Switch.off?
      return "authority_restore_failed" if Authority::State.restore_failed?(harness)
      return "retention_disabled" unless ENV[KILL_SWITCH].to_s.empty?

      state = Config.get("cutover.state", scope: root)
      return "cutover_state_#{state}" unless state == "cutover"
      return "retention_native_off" unless setting("retention.native", false, root) == true

      level = Authority::State.level(harness)
      return "authority_codex_#{level}" if harness == "codex" && level != Authority::State::SPOOL
      return "authority_rehearse" if level == Authority::State::REHEARSE

      nil
    end

    def window_days(root, harness = "claude")
      days = setting("retention.native_days", DEFAULT_DAYS, root)
      return days if days == 0 && ZERO_LEVELS.include?(Authority::State.level(harness))

      days.is_a?(Integer) && days.positive? ? days : DEFAULT_DAYS
    end

    def window_policy(root, harness)
      days = window_days(root, harness)
      purge = setting("retention.purge", false, root) == true && ZERO_LEVELS.include?(Authority::State.level(harness))
      applied = Authority::State.applied_ns(harness)
      lambda do |newest_ns|
        older = !applied.nil? && newest_ns < applied
        next 0 if older && purge
        next nil if older && days.zero?

        days * DAY_S
      end
    end

    def setting(key, default, root)
      Config.get(key, scope: root)
    rescue UsageError
      default
    end

    def after_registry(context, sessions, totals)
      gates = HARNESSES.to_h { |harness| [harness, gate(context.root, harness)] }
      return if gates.values.all?

      root = Check.transcript_root
      resumed = root ? Remove.resume(context, root) : []
      totals.errors.concat(resumed.select { |item| item["partial"] }.map { |item| { "phase" => "retention", "session_key" => item["session_key"], "error_class" => "RetentionPartial", "message" => "resumed receipt #{item['receipt_id']} kept #{item['kept'].size} changed files" } })
      by_key = sessions.to_h { |session| [session.key, session] }
      Record::Scope.session_keys(context.root).each do |key|
        session = by_key[key]
        next if session&.failed

        harness = key.split("-", 2).first
        next if gates[harness] || !HARNESSES.include?(harness)

        process(context, key, session, harness, totals)
      rescue StandardError => e
        totals.errors << { "phase" => "retention", "session_key" => key, "error_class" => e.class.name, "message" => e.message[0, 200] }
      end
    rescue StandardError => e
      totals.errors << { "phase" => "retention", "error_class" => e.class.name, "message" => e.message[0, 200] }
    end

    def process(context, key, session, harness, totals)
      window = window_policy(context.root, harness)
      result = if harness == "codex"
                 CodexRollouts.evaluate(context, key, window, session: session)
               else
                 Check.evaluate(context, key, window, session: session)
               end
      return unless result
      return hold(result, result.condition, totals) if result.state == "held"
      return unless result.state == "candidate"

      days = window_days(context.root, harness)
      failure = harness == "codex" ? CodexRollouts.remove(context, result, days) : Remove.run(context, result, days, Check.transcript_root)
      hold(result, failure, totals) if failure
    end

    def hold(result, condition, totals)
      session = result.session
      return unless session

      session.gap(GAP, "retention/#{condition}", agent_key: Ids::MAIN_AGENT, ts: session.first_ts || Record::FS.rfc3339_ms(0),
                                                 detail: { "condition" => condition }.merge(result.detail.is_a?(Hash) ? result.detail.slice("tool_counts") : {}))
      totals.absorb(session.flush)
    end

    def report(scopes)
      scopes.reject { |scope| scope["gone"] }.map do |scope|
        root = scope["root"]
        context = Deriver::Context.new(root)
        days = window_days(root)
        buckets = Hash.new { |hash, state| hash[state] = [] }
        Record::Scope.session_keys(root).each do |key|
          result = Check.evaluate(context, key, days * DAY_S)
          next unless result

          buckets[result.state] << entry(result)
        end
        { "scope_id" => scope["scope_id"], "root" => root, "gate" => gate(root), "window_days" => days,
          "candidates" => buckets["candidate"], "held" => buckets["held"], "waiting" => buckets["waiting"],
          "gone" => buckets["gone"].size, "pending" => pending(root), "removed" => removed(root) }
      end
    end

    def entry(result)
      item = { "session_key" => result.session_key, "condition" => result.condition }
      item["files"] = result.files.size if result.files
      item["bytes"] = result.files.sum { |file| file["size"] } if result.files
      item["newest_at"] = Record::FS.rfc3339_ms(result.newest_ns) if result.newest_ns&.positive?
      item["detail"] = result.detail if result.detail
      item.compact
    end

    def removed(root)
      applied = Remove.receipts(root).select { |receipt| receipt["phase"] == Remove::APPLIED }
      files = applied.flat_map { |receipt| Array(receipt["removed"]) }.uniq { |path| path["path"] }
      { "sessions" => applied.map { |receipt| receipt["session_key"] }.uniq.size, "files" => files.size,
        "bytes" => files.sum { |path| path["bytes"].to_i }, "partial" => applied.count { |receipt| receipt["partial"] } }
    end

    def pending(root)
      Remove.open_receipts(root).map do |receipt|
        { "session_key" => receipt["session_key"], "receipt_id" => receipt["receipt_id"], "at" => receipt["at"],
          "files" => Array(receipt["paths"]).size, "present" => Array(receipt["paths"]).count { |path| Record::FS.lexists?(path["path"]) } }
      end
    end

    def text(scopes)
      scopes.map do |scope|
        lines = ["#{scope['root']}: retention #{scope['gate'] ? "off (#{scope['gate']})" : 'on'}, window #{scope['window_days']} days; " \
                 "removed #{scope['removed']['sessions']} sessions, #{scope['removed']['files']} files, #{scope['removed']['bytes']} bytes"]
        scope["pending"].each do |item|
          lines << "  pending #{item['session_key']}: receipt #{item['receipt_id']} from #{item['at']}, #{item['present']} of #{item['files']} files still present; the next derive resumes it"
        end
        scope["candidates"].each { |item| lines << "  candidate #{item['session_key']} (#{item['files']} files, #{item['bytes']} bytes)" }
        scope["held"].each { |item| lines << "  held #{item['session_key']}: #{item['condition']}" }
        scope["waiting"].each { |item| lines << "  waiting #{item['session_key']}: newest file #{item['newest_at']}" }
        lines.join("\n")
      end.join("\n")
    end
  end
end
