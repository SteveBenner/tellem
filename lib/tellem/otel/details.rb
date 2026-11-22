# frozen_string_literal: true

require_relative "../record/reader"
require_relative "settings"

module Tellem
  module Otel
    module Details
      HARNESS = "claude"
      SOURCE = "otel"
      MISMATCH = "otel_mismatch"
      COUNTERS = {
        "input_tokens" => "input_tokens", "output_tokens" => "output_tokens",
        "cache_read_tokens" => "cache_read_input_tokens", "cache_creation_tokens" => "cache_creation_input_tokens"
      }.freeze

      module_function

      def derive(session)
        return unless session.harness == HARNESS

        events = spool(session)
        expect = Settings.enabled?
        return if events.empty? && !expect

        requests = requests(session)
        written = session.of("usage_detail").to_h { |record| [record["body"]["request_key"], true] }
        seen = {}
        events.each do |event|
          agent, entry = requests[event["request_id"]]
          next unless entry

          key = entry["request_key"]
          next if seen[key] || written[key]

          seen[key] = true if consider(session, agent, entry, event, written)
        end
        expect(session, requests, written) if expect
      end

      def consider(session, agent, entry, event, written)
        differs = differences(event, entry)
        if differs.empty?
          session.add("usage_detail", agent_key: agent, ts: event["ts"], body: body(entry, event))
          written[entry["request_key"]] = true
          return true
        end
        return false unless session.overdue?(entry["ts"])

        session.gap(MISMATCH, "otel/#{entry['request_key']}", agent_key: agent, ts: entry["ts"],
                                                             detail: { "fields" => differs }, harness_version: session.harness_version)
        true
      end

      def expect(session, requests, written)
        requests.each_value do |_agent, entry|
          session.overdue?(entry["ts"]) unless written[entry["request_key"]]
        end
      end

      def spool(session)
        records, read = Record::Reader.records(Settings.spool(session.key))
        session.raw_entries[Settings::SPOOL_ENTRY] = { "inode" => read["inode"], "offset" => read["offset"] } if read["inode"]
        records.select { |record| record["request_id"].is_a?(String) && record["ts"].is_a?(String) }
      rescue Tellem::Error
        []
      end

      def requests(session)
        session.batches.keys.sort.each_with_object({}) do |agent, out|
          session.batches[agent].usage.each do |entry|
            ts = entry["ts"] || session.batches[agent].started_at || session.first_ts
            id = entry["provider_request_id"]
            next unless ts && entry["request_key"].is_a?(String) && id.is_a?(String)

            out[id] ||= [agent, entry.merge("ts" => ts)]
          end
        end
      end

      def differences(event, entry)
        names = []
        names << "model" unless event["model"] == entry["model"]
        COUNTERS.each { |from, to| names << to unless event[from] == entry[to] }
        names
      end

      def body(entry, event)
        {
          "harness" => HARNESS, "request_key" => entry["request_key"], "effort" => event["effort"], "cost_usd" => event["cost_usd"],
          "ttft_ms" => event["ttft_ms"], "duration_ms" => event["duration_ms"], "query_source" => event["query_source"],
          "agent_name" => event["agent_name"], "source" => SOURCE
        }
      end
    end
  end
end
