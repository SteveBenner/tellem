# frozen_string_literal: true

require_relative "../errors"
require_relative "../ids"
require_relative "../record/pointers"
require_relative "agent_time"
require_relative "agents"
require_relative "records"
require_relative "scopes"
require_relative "tasks"
require_relative "text"

module Tellem
  module Reports
    module Tree
      module_function

      def run(scopes, session: nil)
        load = Agents.loader
        if session
          raise UsageError.new("#{session} is not a session key") unless Ids.valid_session_key?(session)

          found = Agents.in_session(scopes, session, Ids::MAIN_AGENT, load)
          raise OperationalFailure.new("no session #{session} in the covered scopes", next_command: "tellem sessions --all") unless found

          return [gone(found.gone)] if found.gone

          return annotate([build(found.data, session)], Tasks.session_breakdown(scopes, session: session))
        end
        sessions = Scopes.live(scopes).flat_map do |scope|
          data = load.call(scope)
          data.session_keys.map { |key| build(data, key) }
        end.sort_by { |item| [item["started_at"].to_s, item["session_key"]] }
        annotate(sessions, Tasks.session_breakdown(scopes))
      end

      def annotate(sessions, breakdown)
        return sessions if breakdown.nil?

        sessions.each do |session|
          session["tasks"] = Tasks.cells(breakdown, session["session_key"])
          session["agents"].each { |agent| mark(agent, breakdown, session["session_key"]) }
        end
      end

      def mark(agent, breakdown, session_key)
        agent["tasks"] = Tasks.cells(breakdown, session_key, agent["agent_key"])
        agent["children"].each { |child| mark(child, breakdown, session_key) }
      end

      def gone(pointer)
        { "session_key" => pointer["session_key"], "gone" => true, "pointer" => pointer }
      end

      def build(data, session_key)
        agents = Agents.agents(data, session_key)
        kids = Agents.children(agents)
        counts = message_counts(data, session_key)
        mode, idle = AgentTime.settings(data)
        now = Time.now.to_f
        node = lambda do |key, trail|
          agent = agents.fetch(key)
          out = agent.reject { |field, _| field == "home_place_id" }
          out["home"] = Records.place(data.places, agent["home_place_id"])
          out["messages"] = counts.fetch(key) { { "sent" => 0, "received" => 0 } }
          out["time"] = AgentTime.for(data, session_key, key, mode: mode, idle_seconds: idle, now: now)
          out["children"] = trail.include?(key) ? [] : kids[key].map { |child| node.call(child, trail + [key]) }
          out
        end
        Agents.session(data, session_key).merge("gone" => false, "agents" => Agents.roots(agents).map { |key| node.call(key, []) })
      end

      def message_counts(data, session_key)
        counts = Hash.new { |hash, agent| hash[agent] = { "sent" => 0, "received" => 0 } }
        data.of_kind("message").each do |record|
          next unless record["session_key"] == session_key

          body = record["body"] || {}
          if body["channel"] == "receive"
            counts[body["to_agent_key"]]["received"] += 1 if body["from_agent_key"].nil? && body["to_agent_key"]
          else
            counts[body["from_agent_key"]]["sent"] += 1 if body["from_agent_key"]
            counts[body["to_agent_key"]]["received"] += 1 if body["to_agent_key"]
          end
        end
        counts
      end

      def text(sessions)
        return "(no sessions)" if sessions.empty?

        sessions.flat_map do |session|
          if session["gone"]
            pointer = session["pointer"]
            next ["#{session['session_key']}  gone (home #{pointer['home_root']}, #{pointer['first_at']} .. #{pointer['last_at']})"]
          end

          head = "#{session['session_key']}  #{session['started_at'] || '-'} .. #{session['ended_at'] || '-'}  home #{Text.place(session['home'])}#{task_suffix(session)}"
          [head] + session["agents"].flat_map { |agent| lines(agent, 1) }
        end.join("\n")
      end

      def message_suffix(node)
        counts = node["messages"]
        counts && (counts["sent"].positive? || counts["received"].positive?) ? "  msgs #{counts['sent']}/#{counts['received']}" : ""
      end

      def time_suffix(node)
        line = AgentTime.line(node["time"])
        line ? "  #{line}" : ""
      end

      def task_suffix(node)
        node.key?("tasks") ? "  tasks #{Tasks.cell_text(node['tasks'])}" : ""
      end

      def lines(agent, depth)
        detail = [agent["agent_type"], agent["model"], agent["effort"], agent["isolation"]].compact.join(" ")
        evidence = agent["parent_agent_key"] ? " parent #{agent['parent_agent_key']} via #{agent['spawn_tool_use_id'] || '-'} (#{Text.cell(agent['evidence'])})" : ""
        line = "#{'  ' * depth}#{agent['agent_key']}  #{detail.empty? ? '-' : detail}  home #{Text.place(agent['home'])}#{evidence}#{task_suffix(agent)}#{message_suffix(agent)}#{time_suffix(agent)}"
        [line] + agent["children"].flat_map { |child| lines(child, depth + 1) }
      end
    end
  end
end
