# frozen_string_literal: true

require_relative "../ingest/support"

module Tellem
  module Deriver
    module Reach
      module_function

      def derive(session)
        full = session.context.flag?("commands.full")
        seen = {}
        session.all_raw.each do |record|
          next unless record["event"] == "post_tool" && record["tool_use_id"].is_a?(String)
          next unless Ingest::Support.tool_type(record["tool"]) == "shell"

          seen[record["tool_use_id"]] = true
          call = session.calls[record["tool_use_id"]]
          shell(session, record["tool_use_id"], session.raw_agent(record["id"]), record["ts"], record["cwd"], record["program"],
                call, full)
        end
        session.calls.keys.sort.each do |id|
          call = session.calls[id]
          next if seen[id] || call["tool"]["type"] != "shell" || !call["tool"]["result_at"].is_a?(String)
          next if Ingest::Support.code_mode_call?(call["tool"]["name"], call["tool"]["input"])

          shell(session, id, call["agent"], call["ts"] || call["tool"]["result_at"], call["tool"]["cwd"], nil, call, full)
        end
      end

      def shell(session, id, agent, ts, cwd, program, call, full)
        command = call && Ingest::Support.shell_command(call["tool"]["name"], call["tool"]["input"])
        extracted = command.is_a?(String) ? extract(session, command, cwd) : nil
        place = session.local_place(cwd, agent_key: agent, ts: ts)
        body = { "tool_use_id" => id, "place_id" => place && place["place_id"],
                 "program" => program || (extracted && extracted["program"]) }
        body["command"] = session.context.seam(:remote).redacted_command(command) if full && command.is_a?(String)
        session.add("shells_out", agent_key: agent, ts: ts, body: body)
        Array(extracted && extracted["reaches"]).each do |reach|
          target = session.add_place(reach["place"], agent_key: agent, ts: ts)
          next unless target

          session.add("reaches", agent_key: agent, ts: ts, body: {
                        "tool_use_id" => id, "place_id" => target["place_id"], "via_program" => reach["via_program"],
                        "evidence" => reach["evidence"]
                      })
        end
      end

      def extract(session, command, cwd)
        session.context.seam(:remote).extract(command, cwd: cwd, git_remote_lookup: session.context.git_lookup)
      rescue StandardError
        nil
      end
    end
  end
end
