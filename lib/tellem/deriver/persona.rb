# frozen_string_literal: true

require_relative "../ids"
require_relative "../ingest/support"

module Tellem
  module Deriver
    module Persona
      AUTHORITIES = %w[transcript_observed sampled unknown].freeze
      UNKNOWN = "unknown"

      module_function

      def derive(session)
        return unless session.context.flag?("features.persona")

        identity = identity(session)
        session.batches.keys.sort.each do |agent|
          session.batches[agent].persona_results.each do |result|
            evidence = safe { identity.from_tool_result(text: result["text"], at: result["at"]) }
            record(session, agent, evidence)
          end
        end
        return if session.fresh.empty?

        snapshot = safe { identity.snapshot(harness: session.harness, session_id: session.session_id) }
        record(session, Ids::MAIN_AGENT, snapshot) if snapshot.is_a?(Hash) && changed?(session, snapshot)
      end

      def record(session, agent, evidence)
        body = body(evidence)
        return unless body

        session.add("persona", agent_key: agent, ts: body["effective_at"], body: body)
      end

      def body(evidence)
        return nil unless evidence.is_a?(Hash)

        data = evidence.transform_keys(&:to_s)
        at = Ingest::Support.rfc3339_ms(data["effective_at"].to_s)
        authority = data["authority"].to_s
        revision = data["revision"]
        return nil unless at && AUTHORITIES.include?(authority) && (revision.is_a?(String) || revision.is_a?(Integer))

        members = Array(data["members"]).select { |member| member.is_a?(Hash) }.map do |member|
          member.transform_keys(&:to_s).slice("name", "version", "digest")
        end
        { "revision" => revision, "members" => members, "lead" => data["lead"], "speaker" => data["speaker"],
          "authority" => authority, "effective_at" => at }
      end

      def changed?(session, snapshot)
        body = body(snapshot)
        return false unless body

        latest = session.of("persona").max_by { |record| record["body"]["effective_at"].to_s }
        latest.nil? || latest["body"].slice("revision", "members", "lead") != body.slice("revision", "members", "lead")
      end

      def evidence(session)
        records = session.of("persona").sort_by { |record| [record["body"]["effective_at"].to_s, record["id"].to_s] }
        return records unless session.context.flag?("features.persona")

        identity = identity(session)
        return records unless identity.respond_to?(:evidence_from)

        markers = session.batches.keys.sort.flat_map do |agent|
          Array(safe { identity.evidence_from(session.batches[agent].persona_results) })
        end
        records + markers.select { |item| item.is_a?(Hash) && item["authority"] == UNKNOWN }
      end

      def attribution(session, evidence, ts)
        identity = identity(session)
        found = identity.respond_to?(:attribute) ? safe { identity.attribute([{ "ts" => ts }], evidence).first } : nil
        return [nil, UNKNOWN] unless found.is_a?(Hash) && found["persona_key"] != UNKNOWN

        [found["persona"], found["persona_key"]]
      end

      def identity(session)
        seam = session.context.seam(:identity)
        seam.respond_to?(:for_scope) ? seam.for_scope(session.context.root) : seam
      end

      def safe
        yield
      rescue StandardError
        nil
      end
    end
  end
end
