# frozen_string_literal: true

require_relative "../ids"
require_relative "../record/fs"
require_relative "lifecycle"

module Tellem
  module Deriver
    module Agents
      MAIN = Ids::MAIN_AGENT
      SYNTHETIC = "<synthetic>"
      TYPE_KEYS = %w[subagent_type agent_type role].freeze

      module_function

      def derive(session)
        session_record(session)
        spawns(session)
        session.agent_keys.each { |agent| agent_record(session, agent) }
        missing_starts(session)
      end

      def missing_starts(session)
        session.agent_keys.each do |agent|
          next if agent == MAIN || !Lifecycle.start_lost?(session, agent)

          link = session.links[agent]
          ts = Lifecycle.spawn_ts(link)
          session.gap("missing_subagent_start", "raw/#{agent}", agent_key: agent, ts: ts,
                                                                detail: { "agent_key" => agent, "spawn_tool_use_id" => link["tool_use_id"] },
                                                                harness_version: session.harness_version)
        end
      end

      def session_record(session)
        return unless session.of("session").empty?

        started = session.first_ts
        return unless started

        home = session.local_place(session.root, agent_key: MAIN, ts: started)
        session.add("session", agent_key: MAIN, ts: started, body: {
                      "harness" => session.harness, "harness_version" => session.harness_version, "host" => Record::FS.host,
                      "home_place_id" => home && home["place_id"], "started_at" => started,
                      "ended_at" => session.session_end&.fetch("ts", nil)
                    })
      end

      def spawn_calls(session)
        names = session.context.spawn_tools(session.harness)
        session.calls.keys.sort.filter_map do |id|
          call = session.calls[id]
          [id, call] if names.include?(call["tool"]["name"])
        end
      end

      def spawns(session)
        children = session.links.to_h { |child, link| [link["tool_use_id"], child] }
        spawn_calls(session).each do |id, call|
          next unless call["tool"]["result_at"].is_a?(String)

          parent = call["agent"]
          ts = call["ts"] || call["tool"]["result_at"]
          child = children[id]
          place = session.standing_at(parent, ts) || session.home[parent]
          session.add("spawn", agent_key: parent, ts: ts, body: {
                        "spawn_tool_use_id" => id, "parent_agent_key" => parent, "child_agent_key" => child,
                        "spawned_at_place_id" => place && place["place_id"], "requested_type" => requested_type(call),
                        "isolation" => child ? isolation(session, child, parent, call) : nil
                      })
        end
      end

      def requested_type(call)
        input = call && call["tool"]["input"]
        return nil unless input.is_a?(Hash)

        TYPE_KEYS.map { |key| input[key] }.find { |value| value.is_a?(String) && !value.empty? }
      end

      def isolation(session, child, parent, call)
        home = session.home[child]
        standing = session.standing_at(parent, call ? call["ts"].to_s : "") || session.home[parent]
        if full?(home) && full?(standing) && home["repository_id"]
          return "shared" unless home["repository_id"] == standing["repository_id"]

          mine = home.dig("attributes", "worktree_root")
          theirs = standing.dig("attributes", "worktree_root")
          return mine && theirs && mine != theirs ? "worktree" : "shared"
        end
        input = call && call["tool"]["input"]
        input.is_a?(Hash) && input["isolation"] == "worktree" ? "worktree" : "shared"
      end

      def full?(place)
        place.is_a?(Hash) && place["resolved"] == "full"
      end

      def agent_record(session, agent)
        return if session.of("agent").any? { |record| record["agent_key"] == agent }

        ts = first_time(session, agent)
        return unless ts

        body = agent == MAIN ? main_body(session) : sub_body(session, agent)
        return unless body

        body["home_place_id"] = session.home[agent] && session.home[agent]["place_id"]
        session.add("agent", agent_key: agent, ts: ts, body: body)
      end

      def main_body(session)
        model = model(session, MAIN)
        return nil unless model || !session.stops.empty?

        { "parent_agent_key" => nil, "spawn_tool_use_id" => nil, "agent_type" => agent_type(session, MAIN), "model" => model,
          "effort" => nil, "isolation" => nil, "evidence" => "none" }
      end

      def sub_body(session, agent)
        link = session.links[agent]
        return nil unless session.stopped? || (link && (model(session, agent) || final?(session, agent)))

        parent, spawn, evidence = link ? [link["parent"], link["tool_use_id"], link["evidence"] || "transcript_link"] : hook_link(session, agent)
        isolation = link ? isolation(session, agent, link["parent"], link["call"]) : nil
        { "parent_agent_key" => parent, "spawn_tool_use_id" => spawn, "agent_type" => agent_type(session, agent),
          "model" => model(session, agent), "effort" => nil, "isolation" => isolation, "evidence" => evidence }
      end

      def final?(session, agent)
        return true if session.raw[agent].to_a.any? { |record| record["event"] == "subagent_stop" }

        session.of("lifecycle").any? { |record| record["agent_key"] == agent && %w[stopped failed].include?(record["body"]["state"]) }
      end

      def hook_link(session, agent)
        started = session.raw[agent].to_a.any? { |record| record["event"] == "subagent_start" }
        return [nil, nil, "none"] unless started

        spawners = spawn_calls(session).map { |_id, call| call["agent"] }.uniq - [agent]
        spawners.size == 1 ? [spawners.first, nil, "subagent_start"] : [nil, nil, "none"]
      end

      def agent_type(session, agent)
        typed = session.raw[agent].to_a.find { |record| record["agent_type"].is_a?(String) }
        return typed["agent_type"] if typed

        batch = session.batches[agent]
        return batch.agent_role if batch&.agent_role

        link = session.links[agent]
        link && requested_type(link["call"])
      end

      def model(session, agent)
        batch = session.batches[agent]
        return nil unless batch

        found = batch.exchanges.find do |exchange|
          exchange["role"] == "agent" && exchange["model"].is_a?(String) && exchange["model"] != SYNTHETIC && !exchange["model"].empty?
        end
        found && found["model"]
      end

      def first_time(session, agent)
        session.raw[agent].to_a.first&.fetch("ts", nil) || session.batches[agent]&.started_at
      end
    end
  end
end
