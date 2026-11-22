# frozen_string_literal: true

require "time"
require_relative "../ids"
require_relative "../record/formats"

module Tellem
  module Identity
    module Timeline
      UNKNOWN = "unknown"
      NONE = "none"
      AUTHORITIES = %w[transcript_observed sampled unknown].freeze
      DIGEST_WIDTH = 24

      module_function

      def attribute(observations, evidence)
        line = ordered(evidence)
        times = line.map(&:first)
        Array(observations).map do |observation|
          at = time_of(observation)
          next unknown_ref unless at

          index = times.bsearch_index { |time| time > at }
          index = index.nil? ? line.length - 1 : index - 1
          index.negative? ? unknown_ref : ref(line[index].last)
        end
      end

      def evidence_from(persona_results, identity)
        Array(persona_results).filter_map do |result|
          text = field(result, "text")
          at = field(result, "at")
          found = identity.from_tool_result(text: text, at: at)
          found.is_a?(Hash) ? normalize(found) : unknown(at)
        end
      end

      def unknown(at)
        stamp = rfc3339(at)
        return nil unless stamp

        { "members" => nil, "lead" => nil, "revision" => nil, "speaker" => nil, "authority" => UNKNOWN, "effective_at" => stamp }
      end

      def known?(evidence)
        evidence.is_a?(Hash) && evidence["authority"] != UNKNOWN && evidence["members"].is_a?(Array)
      end

      def persona_key(evidence)
        return UNKNOWN unless known?(evidence)

        names = evidence["members"].map { |member| member["name"] }.uniq.sort
        return NONE if names.empty?

        key = names.join("+")
        lead = evidence["lead"]
        names.length >= 2 && lead.is_a?(String) && !lead.empty? ? "#{key} lead #{lead}" : key
      end

      def members_digest(members)
        rows = Array(members).map { |member| { "name" => member["name"], "version" => member["version"], "digest" => member["digest"] } }
        Ids.sha256(Ids.canonical_json(rows.sort_by { |row| [row["name"].to_s, row["version"].to_s, row["digest"].to_s] }))[0, DIGEST_WIDTH]
      end

      def ref(evidence)
        return unknown_ref unless known?(evidence)

        {
          "persona_key" => persona_key(evidence),
          "members_digest" => members_digest(evidence["members"]),
          "lead" => evidence["lead"],
          "speaker" => evidence["speaker"],
          "authority" => evidence["authority"],
          "revision" => evidence["revision"],
          "effective_at" => evidence["effective_at"]
        }
      end

      def unknown_ref
        {
          "persona_key" => UNKNOWN, "members_digest" => nil, "lead" => nil, "speaker" => nil,
          "authority" => UNKNOWN, "revision" => nil, "effective_at" => nil
        }
      end

      def usage_attribution(ref)
        {
          "persona" => { "members_digest" => ref["members_digest"], "lead" => ref["lead"], "authority" => ref["authority"] },
          "persona_key" => ref["persona_key"]
        }
      end

      def record(evidence, session_key:, agent_key:)
        item = normalize(evidence)
        return nil unless known?(item) && item["revision"].is_a?(Integer)

        body = item.slice("revision", "members", "lead", "speaker", "authority", "effective_at")
        Record::Formats.derived(kind: "persona", session_key: session_key, agent_key: agent_key, ts: item["effective_at"], body: body)
      end

      def ordered(evidence)
        Array(evidence).each_with_index.filter_map do |item, index|
          entry = normalize(item)
          at = entry && time_of(entry["effective_at"])
          [at, index, entry] if at
        end.sort_by { |at, index, _| [at, index] }.map { |at, _, entry| [at, entry] }
      end

      def normalize(item)
        return nil unless item.is_a?(Hash)

        data = item.transform_keys(&:to_s)
        data = data["body"].transform_keys(&:to_s) if data["kind"] == "persona" && data["body"].is_a?(Hash)
        members = data["members"].is_a?(Array) ? data["members"].select { |member| member.is_a?(Hash) }.map { |member| member.transform_keys(&:to_s).slice("name", "version", "digest") } : nil
        authority = AUTHORITIES.include?(data["authority"]) ? data["authority"] : UNKNOWN
        {
          "members" => members,
          "lead" => data["lead"],
          "revision" => data["revision"],
          "speaker" => data["speaker"],
          "authority" => authority,
          "effective_at" => rfc3339(data["effective_at"])
        }
      end

      def time_of(value)
        value = field(value, "ts") || field(value, "at") || field(value, "timestamp") || field(value, "effective_at") if value.is_a?(Hash)
        case value
        when Time then value.to_r
        when String then Time.iso8601(value).to_r
        end
      rescue ArgumentError
        nil
      end

      def rfc3339(value)
        time = case value
               when Time then value
               when String then Time.iso8601(value)
               end
        time&.utc&.iso8601(3)
      rescue ArgumentError
        nil
      end

      def field(hash, key)
        return nil unless hash.is_a?(Hash)

        hash.key?(key) ? hash[key] : hash[key.to_sym]
      end
    end
  end
end
