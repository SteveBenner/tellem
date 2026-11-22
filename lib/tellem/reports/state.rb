# frozen_string_literal: true

require_relative "agent_time"
require_relative "agents"
require_relative "records"
require_relative "text"

module Tellem
  module Reports
    module State
      WORKSPACE = %w[status cause branch dirty worktree ahead behind duration_ms].freeze

      module_function

      def run(scopes, spec, since: nil)
        load = Agents.loader
        found = Agents.locate(scopes, spec, load)
        return { "agent" => spec, "gone" => true, "pointer" => found.gone, "timeline" => [] } if found.gone

        data = found.data
        session_key = found.session_key
        agent_key = found.agent_key
        info = Agents.agents(data, session_key)[agent_key] || {}
        lifecycle = data.for_agent("lifecycle", session_key, agent_key)
        context = data.for_agent("context", session_key, agent_key)
        places = [info["home_place_id"]] + data.for_agent("stands_in", session_key, agent_key).map { |record| record.dig("body", "place_id") } +
                 context.map { |record| record.dig("body", "standing_place_id") }
        places = places.compact.uniq
        workspace = data.of_kind("workspace").select { |record| places.include?(record.dig("body", "place_id")) }
        entries = (lifecycle + context + workspace).sort_by { |record| Records.sort_key(record) }
        entries = entries.select { |record| record["ts"].to_s >= since } if since
        { "agent" => "#{session_key}/#{agent_key}", "gone" => false, "current" => current(data, info, context, lifecycle).merge("time" => time(data, session_key, agent_key)),
          "timeline" => entries.map { |record| entry(data, record) } }
      end

      def time(data, session_key, agent_key)
        mode, idle = AgentTime.settings(data)
        AgentTime.for(data, session_key, agent_key, mode: mode, idle_seconds: idle, now: Time.now.to_f)
      end

      def current(data, info, context, lifecycle)
        latest = context.max_by { |record| Records.sort_key(record) }
        state = lifecycle.max_by { |record| Records.sort_key(record) }
        body = latest ? latest["body"] || {} : {}
        {
          "model" => latest ? body["model"] : info["model"],
          "effort" => latest ? body["effort"] : info["effort"],
          "branch" => body["branch"],
          "standing" => Records.place(data.places, latest ? body["standing_place_id"] : info["home_place_id"]),
          "since" => latest && latest["ts"],
          "state" => state && state.dig("body", "state"),
          "state_at" => state && state["ts"]
        }
      end

      def entry(data, record)
        body = record["body"] || {}
        out = { "ts" => record["ts"], "kind" => record["kind"] }
        case record["kind"]
        when "lifecycle" then out["state"] = body["state"]
        when "context"
          out.merge!("model" => body["model"], "effort" => body["effort"], "branch" => body["branch"],
                     "standing" => Records.place(data.places, body["standing_place_id"]))
        when "workspace"
          out["place"] = Records.place(data.places, body["place_id"])
          WORKSPACE.each { |field| out[field] = body[field] }
        end
        out
      end

      def text(report)
        if report["gone"]
          pointer = report["pointer"]
          return "#{report['agent']}: session gone (home #{pointer['home_root']})"
        end
        return "#{report['agent']}: (no state recorded)" if report["timeline"].empty?

        lines = report["timeline"].map do |entry|
          detail = case entry["kind"]
                   when "lifecycle" then entry["state"]
                   when "context" then "model #{Text.cell(entry['model'])} effort #{Text.cell(entry['effort'])} branch #{Text.cell(entry['branch'])} at #{Text.place(entry['standing'])}"
                   else "#{Text.place(entry['place'])} #{entry['status']}#{entry['cause'] ? " (#{entry['cause']})" : ''} branch #{Text.cell(entry['branch'])} dirty #{Text.cell(entry['dirty'])}"
                   end
          "#{entry['ts']}  #{entry['kind'].ljust(9)}  #{detail}"
        end
        now = report["current"]
        head = "#{report['agent']}  now #{Text.cell(now['state'])}, model #{Text.cell(now['model'])}, effort #{Text.cell(now['effort'])}"
        figures = AgentTime.line(now["time"])
        head = "#{head}, time #{figures}" if figures
        ([head] + lines).join("\n")
      end
    end
  end
end
