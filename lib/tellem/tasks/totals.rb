# frozen_string_literal: true

module Tellem
  module Tasks
    module Totals
      HOUR = 3600
      MINUTE = 60
      DAY = 86_400

      module_function

      def live?(task, now, rules)
        task["closed"].nil? && !task["merged_into"] && now - task["last_activity"] <= rules["autoclose_hours"] * HOUR
      end

      def totals(task, now, rules)
        live = live?(task, now, rules)
        spans = task["turns"].flat_map { |turn| turn["spans"] }
        agents = task["subagents"]
        running = live && (spans.any? { |span| span[1].nil? } || agents.any? { |agent| agent["end"].nil? })
        horizon = running || (rules["display_elapsed"] == "now" && live) ? now : task["last_activity"]
        active = spans.sum { |span| [0.0, (span[1].nil? ? horizon : span[1]) - span[0]].max }
        spent = agents.sum { |agent| [0.0, (agent["end"].nil? ? horizon : agent["end"]) - agent["start"]].max }
        idle = live && !running && rules["display_elapsed"] == "freeze" ? now - task["last_activity"] : 0.0
        {
          elapsed: [0.0, horizon - task["started"]].max,
          active: active,
          agents: active + spent,
          subagents: agents.length,
          running_subagents: agents.count { |agent| agent["end"].nil? },
          running: running,
          idle: [0.0, idle].max,
          live: live
        }
      end

      def format_duration(seconds)
        seconds = [0, seconds].max.to_i
        return "<1m" if seconds < MINUTE
        return "#{seconds / MINUTE}m" if seconds < HOUR
        return format("%<h>dh%<m>02dm", h: seconds / HOUR, m: seconds % HOUR / MINUTE) if seconds < DAY

        format("%<d>dd%<h>02dh", d: seconds / DAY, h: seconds % DAY / HOUR)
      end

      def summary(values)
        "⏱ #{format_duration(values[:elapsed])} · active #{format_duration(values[:active])} · agents #{format_duration(values[:agents])} (#{values[:subagents]})"
      end

      def format_line(values)
        idle = values[:idle] >= MINUTE ? "idle #{format_duration(values[:idle])}" : ""
        "#{summary(values)}\x1f#{idle}"
      end

      def task_line(task, now, rules)
        name = task["name"].nil? || task["name"].empty? ? "(unnamed)" : task["name"]
        "#{name} — #{summary(totals(task, now, rules))} [#{task['id']}]"
      end
    end
  end
end
