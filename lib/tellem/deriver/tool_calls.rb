# frozen_string_literal: true

require "time"

module Tellem
  module Deriver
    module ToolCalls
      module_function

      def derive(session)
        session.calls.keys.sort.each do |id|
          call = session.calls[id]
          tool = call["tool"]
          ended = tool["result_at"]
          next unless ended.is_a?(String)

          started = call["ts"].is_a?(String) ? call["ts"] : nil
          session.add("tool_call", agent_key: call["agent"], ts: started || ended, body: {
                        "tool_use_id" => id, "agent_key" => call["agent"], "tool" => tool["name"], "started_at" => started,
                        "ended_at" => ended, "duration_ms" => duration(started, ended),
                        "is_error" => [true, false].include?(tool["is_error"]) ? tool["is_error"] : nil
                      })
        end
      end

      def duration(started, ended)
        return nil unless started

        [((Time.iso8601(ended) - Time.iso8601(started)) * 1000).round, 0].max
      rescue ArgumentError
        nil
      end
    end
  end
end
