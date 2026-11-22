# frozen_string_literal: true

require_relative "../ids"

module Tellem
  module Deriver
    module Samples
      module_function

      def derive(session)
        touched(session).each do |tree, record|
          next if session.of("workspace").any? { |known| known["body"]["source_id"] == record["id"] }

          body = session.context.sample(tree)
          next unless body.is_a?(Hash) && body["place_id"] && body["sampled_at"]

          agent = agent_of(session, record)
          session.local_place(tree, agent_key: agent, ts: record["ts"])
          session.add("workspace", agent_key: agent, ts: body["sampled_at"], body: body.merge("source_id" => record["id"]))
        end
      end

      def touched(session)
        trees = {}
        session.fresh.each do |record|
          entry = session.standing[agent_of(session, record)].find { |item| item[2] == record["id"] }
          place = entry && entry[1]
          tree = place && place["resolved"] == "full" ? place.dig("attributes", "worktree_root") : nil
          trees[tree] = record if tree.is_a?(String) && File.directory?(tree)
        end
        trees.sort_by { |tree, _record| tree }
      end

      def agent_of(session, record)
        session.raw_agent(record["id"]) || Ids::MAIN_AGENT
      end
    end
  end
end
