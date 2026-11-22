# frozen_string_literal: true

require "time"
require_relative "../record/fs"
require_relative "../reports/records"
require_relative "settings"
require_relative "state"

module Tellem
  module Otel
    module Status
      HARNESS = "claude"
      MISMATCH = "otel_mismatch"
      REPORTED = %w[port_in_use no_token inherit_failed].freeze

      module_function

      def report(scopes)
        state = State.read
        pid = State.running_pid
        {
          "receiver" => receiver(state, pid), "enabled" => Settings.enabled?, "kill_switch" => Settings.disabled?,
          "host" => Settings::HOST, "port" => Settings.port, "pid" => pid,
          "started_at" => state["started_at"], "last_request_at" => state["last_request_at"],
          "last_event_at" => state["last_event_at"], "last_event_age_s" => age(state["last_event_at"]),
          "events_kept" => state["events_kept"].to_i, "events_ignored" => state["events_ignored"].to_i,
          "requests" => state["requests"].to_i, "refused" => refused(state["refused"]),
          "derived" => derived(scopes)
        }
      end

      def receiver(state, pid)
        return "running" if pid

        REPORTED.include?(state["state"]) ? state["state"] : "stopped"
      end

      def refused(value)
        return {} unless value.is_a?(Hash)

        value.keys.map(&:to_s).sort.to_h { |key| [key, value[key].to_i] }
      end

      def age(stamp)
        return nil unless stamp.is_a?(String)

        [(Time.now - Time.iso8601(stamp)).round, 0].max
      rescue ArgumentError
        nil
      end

      def derived(scopes)
        totals = { "sessions" => 0, "requests" => 0, "with_detail" => 0, "without_detail" => 0, "mismatch_gaps" => 0 }
        scopes.reject { |item| item["gone"] }.each do |scope|
          Reports::Records.derived_files(scope["root"]).each { |key, path| session(key, path, totals) if key.start_with?("#{HARNESS}-") }
        end
        totals
      end

      def session(key, path, totals)
        usage = {}
        superseded = {}
        details = {}
        gaps = 0
        Reports::Records.each_line_record(path, keep: ->(line) { line.include?("usage") || line.include?(MISMATCH) }) do |record|
          body = record["body"].is_a?(Hash) ? record["body"] : {}
          superseded[record["supersedes"]] = true if record["supersedes"]
          case record["kind"]
          when "usage" then usage[record["id"]] = body["request_key"]
          when "usage_detail" then details[body["request_key"]] = true
          when "gap" then gaps += 1 if body["cause"] == MISMATCH
          end
        end
        return unless covered?(key, details)

        requests = usage.reject { |id, _key| superseded[id] }.values.compact.uniq
        with = requests.count { |request_key| details[request_key] }
        totals["sessions"] += 1
        totals["requests"] += requests.size
        totals["with_detail"] += with
        totals["without_detail"] += requests.size - with
        totals["mismatch_gaps"] += gaps
      end

      def covered?(key, details)
        !details.empty? || Record::FS.lexists?(Settings.spool(key))
      end

      def text(data)
        derived = data["derived"]
        refused = data["refused"].map { |cause, count| "#{cause}=#{count}" }.join(", ")
        [
          "receiver #{data['receiver']} on #{data['host']}:#{data['port']}#{data['pid'] ? " (pid #{data['pid']})" : ''}, " \
          "enabled #{data['enabled']}#{data['kill_switch'] ? ', TELLEM_OTEL_DISABLED set' : ''}",
          "last event #{data['last_event_at'] || '-'}#{data['last_event_age_s'] ? " (#{data['last_event_age_s']} s ago)" : ''}",
          "events kept #{data['events_kept']}, ignored #{data['events_ignored']}, refused #{refused.empty? ? '-' : refused}",
          "derived: #{derived['sessions']} sessions, #{derived['requests']} requests, #{derived['with_detail']} with a detail, " \
          "#{derived['without_detail']} without, #{derived['mismatch_gaps']} mismatch gaps"
        ].join("\n")
      end
    end
  end
end
