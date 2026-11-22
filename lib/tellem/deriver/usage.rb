# frozen_string_literal: true

require_relative "../ids"
require_relative "../record/kinds"
require_relative "../otel/details"
require_relative "agents"
require_relative "persona"

module Tellem
  module Deriver
    module Usage
      ATTRIBUTION = %w[subagent_type effort persona persona_key repository_id place_id].freeze
      SESSION_START = "session_start"
      UNKNOWN_BILLING = "unknown"

      module_function

      def fields
        @fields ||= (Record::Kinds.fetch("usage")[:body] | ATTRIBUTION).freeze
      end

      def derive(session)
        latest = latest_by_request(session)
        evidence = Persona.evidence(session)
        modes = marks(session.all_raw, "permission_mode")
        billing = marks(session.all_raw.select { |record| record["event"] == SESSION_START }, "billing")
        session.batches.keys.sort.each do |agent|
          times = session.batches[agent].entries.filter_map { |item| item["at"] if item["at"].is_a?(String) }.sort
          session.batches[agent].usage.each do |entry|
            ts = entry["ts"] || session.batches[agent].started_at || session.first_ts
            next unless ts && entry["request_key"].is_a?(String)

            body = body(session, agent, entry, ts, evidence)
            body["permission_mode"] ||= at(modes, ts) || ""
            body["billing"] = at(billing, ts) || UNKNOWN_BILLING
            key = [body["harness"], body["request_key"]]
            prior = latest[key]
            record = session.add("usage", agent_key: agent, ts: ts, body: body, supersedes: prior && prior["id"])
            latest[key] = record if record
            line(session, agent, body, entry)
            started(session, agent, body, entry, times)
          end
        end
        Otel::Details.derive(session)
      end

      def line(session, agent, body, entry)
        uuid = entry["last_line_uuid"]
        line_at = entry["last_line_at"]
        return unless uuid.is_a?(String) && line_at.is_a?(String)

        session.add("usage_line", agent_key: agent, ts: line_at, body: {
                      "harness" => body["harness"], "request_key" => body["request_key"], "line_uuid" => uuid, "line_at" => line_at
                    })
      end

      def started(session, agent, body, entry, times)
        first = entry["first_line_at"]
        return unless first.is_a?(String)

        index = times.bsearch_index { |time| time >= first } || times.size
        return unless index.positive?

        session.add("request_start", agent_key: agent, ts: times[index - 1], body: {
                      "harness" => body["harness"], "request_key" => body["request_key"], "started_at" => times[index - 1]
                    })
      end

      def marks(records, field)
        records.filter_map { |record| [record["ts"], record[field]] if record[field].is_a?(String) && record["ts"].is_a?(String) }
      end

      def at(marks, ts)
        index = marks.bsearch_index { |mark| mark[0] > ts } || marks.size
        index.positive? ? marks[index - 1][1] : nil
      end

      def latest_by_request(session)
        session.of("usage").each_with_object({}) do |record, out|
          out[[record["body"]["harness"], record["body"]["request_key"]]] = record
        end
      end

      def body(session, agent, entry, ts, evidence)
        place = session.standing_at(agent, ts) || session.home[agent]
        persona, persona_key = Persona.attribution(session, evidence, ts)
        filled = {
          "harness" => entry["harness"] || session.harness,
          "subagent_type" => agent == Ids::MAIN_AGENT ? nil : Agents.agent_type(session, agent),
          "effort" => effort(session, agent),
          "persona" => persona,
          "persona_key" => persona_key,
          "repository_id" => place && place["repository_id"],
          "place_id" => place && place["place_id"]
        }
        fields.to_h { |field| [field, filled.key?(field) ? filled[field] : entry[field]] }
      end

      def effort(session, agent)
        record = session.of("agent").find { |item| item["agent_key"] == agent }
        record && record["body"]["effort"]
      end
    end
  end
end
