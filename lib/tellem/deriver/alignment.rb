# frozen_string_literal: true

require_relative "../ids"
require_relative "../ingest/support"
require_relative "../record/fs"
require_relative "locations"
require_relative "agents"
require_relative "tool_calls"

module Tellem
  module Deriver
    module Alignment
      OPS = { "read" => "read", "search" => "search", "write" => "write" }.freeze
      PATH_KEYS = %w[file_path path notebook_path].freeze

      module_function

      def derive(session)
        index_calls(session)
        ToolCalls.derive(session)
        session.agent_keys.each { |agent| session.home[agent] ||= Locations.transcript_home(session, agent) }
        raw_works(session)
        unmatched(session)
        Agents.derive(session)
      end

      def index_calls(session)
        session.batches.each do |agent, batch|
          batch.exchanges.each do |exchange|
            tool = exchange["tool"]
            next unless exchange["kind"] == "tool" && tool.is_a?(Hash) && tool["id"].is_a?(String)

            session.calls[tool["id"]] = { "agent" => agent, "tool" => tool, "ts" => exchange["ts"] }
          end
          batch.subagents.each do |link|
            child = Ids.agent_key(link["agent_id"])
            call = session.calls[link["tool_use_id"]]
            next unless child && call && child != agent

            session.links[child] ||= { "parent" => agent, "tool_use_id" => link["tool_use_id"], "call" => call }
          end
        end
        thread_parents(session)
      end

      def thread_parents(session)
        threads = session.batches.each_with_object({}) { |(agent, batch), out| out[batch.thread_id] = agent if batch.thread_id }
        threads[session.session_id] ||= Ids::MAIN_AGENT
        session.batches.keys.sort.each do |agent|
          batch = session.batches[agent]
          next if agent == Ids::MAIN_AGENT || session.links[agent] || batch.parent_thread_id.nil?

          parent = threads[batch.parent_thread_id]
          next unless parent && parent != agent

          session.links[agent] = { "parent" => parent, "tool_use_id" => nil, "call" => nil, "evidence" => "parent_thread_id" }
        end
      end

      def post_tools(session)
        session.all_raw.select { |record| record["event"] == "post_tool" }
      end

      def raw_works(session)
        post_tools(session).each do |record|
          op = OPS[Ingest::Support.tool_type(record["tool"])]
          next unless op

          agent = session.raw_agent(record["id"])
          Array(record["paths"]).grep(String).each do |path|
            place = session.local_place(path, base: record["cwd"], agent_key: agent, ts: record["ts"])
            next unless place

            session.add("works_in", agent_key: agent, ts: record["ts"], body: {
                          "source_id" => record["id"], "place_id" => place["place_id"], "op" => op, "tool" => record["tool"]
                        })
          end
        end
      end

      def unmatched(session)
        raw_ids = post_tools(session).filter_map { |record| record["tool_use_id"] }.to_h { |id| [id, true] }
        newest = session.all_raw.last&.fetch("ts", nil)
        unmatched_raw(session, raw_ids)
        return unless newest

        session.calls.keys.sort.each do |id|
          call = session.calls[id]
          next if raw_ids[id] || call["tool"]["server"] == true || Lifecycle.imported?(session, call["tool"]["result_at"]) ||
                  !session.overdue?(call["tool"]["result_at"]) ||
                  Ingest::Support.code_mode_call?(call["tool"]["name"], call["tool"]["input"])

          agent = call["agent"]
          session.gap("unmatched_tool_call", "align/#{agent}/#{id}", agent_key: agent,
                                                                     ts: call["ts"] || first_time(session, agent),
                                                                     detail: { "tool_calls" => 1 }, count: 1,
                                                                     harness_version: session.harness_version)
          transcript_works(session, id, call)
        end
      end

      def unmatched_raw(session, _raw_ids)
        return if session.batches.empty?

        counts = Hash.new(0)
        post_tools(session).each do |record|
          id = record["tool_use_id"]
          counts[session.raw_agent(record["id"])] += 1 if id.nil? || !session.calls.key?(id)
        end
        counts.each do |agent, count|
          session.gap("unmatched_raw", "align/#{agent}", agent_key: agent, ts: first_time(session, agent),
                                                          detail: { "observations" => count }, count: count,
                                                          harness_version: session.harness_version)
        end
      end

      def transcript_works(session, id, call)
        tool = call["tool"]
        op = OPS[tool["type"]]
        input = tool["input"]
        return unless op && input.is_a?(Hash)

        ts = call["ts"] || first_time(session, call["agent"])
        PATH_KEYS.map { |key| input[key] }.grep(String).each do |path|
          place = session.local_place(path, base: tool["cwd"], agent_key: call["agent"], ts: ts)
          next unless place

          session.add("works_in", agent_key: call["agent"], ts: ts, body: {
                        "source_id" => id, "place_id" => place["place_id"], "op" => op, "tool" => tool["name"]
                      })
        end
      end

      def first_time(session, agent)
        session.raw[agent].to_a.first&.fetch("ts", nil) || session.batches[agent]&.started_at || session.first_ts ||
          Record::FS.rfc3339_ms(0)
      end
    end
  end
end
