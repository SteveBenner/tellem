# frozen_string_literal: true

require "time"
require_relative "../config/resolver"
require_relative "../ids"
require_relative "../tasks/totals"
require_relative "records"

module Tellem
  module Reports
    module AgentTime
      MAIN = Ids::MAIN_AGENT
      FINAL = %w[stopped failed].freeze
      ACTIVITY_KINDS = %w[usage tool_call works_in shells_out message lifecycle context].freeze
      MODES = %w[spans activity both].freeze
      DECIMALS = 3

      @indexes = ObjectSpace::WeakMap.new
      @spawns = ObjectSpace::WeakMap.new

      module_function

      def settings(data)
        root = data.scope["root"]
        [Config.get("time.active", scope: root), Config.get("time.idle_seconds", scope: root)]
      end

      def for(data, session_key, agent_key, mode:, idle_seconds:, now:)
        mode = "spans" unless MODES.include?(mode)
        records = index(data).fetch([session_key, agent_key], [])
        life = records.select { |record| record["kind"] == "lifecycle" }.sort_by { |record| Records.sort_key(record) }
        agent = records.select { |record| record["kind"] == "agent" }.min_by { |record| Records.sort_key(record) }
        started = life.find { |record| record.dig("body", "state") == "started" } || agent
        finals = life.select { |record| FINAL.include?(record.dig("body", "state")) }
        last = records.filter_map { |record| epoch(record["ts"]) if ACTIVITY_KINDS.include?(record["kind"]) }.max
        start = started && epoch(started["ts"])
        stop = finals.map { |record| epoch(record["ts"]) }.compact.max
        horizon = [last, now].compact.min
        finish = stop || horizon
        ending = [stop, horizon].compact.max
        main = agent_key == MAIN
        spans = main ? main_spans(life, horizon, stop) : (start && finish ? [[start, finish]] : [])
        spans_total = spans.empty? ? nil : spans.sum { |from, to| [to - from, 0.0].max }
        gaps = mode == "spans" ? nil : activity(records, idle_seconds)
        figures = {
          "wall" => start && ending ? [ending - start, 0.0].max : nil,
          "active_spans" => mode == "activity" ? nil : spans_total,
          "active_activity" => gaps,
          "waiting" => main ? waiting(life) : nil,
          "spawn_to_stop" => main ? nil : spawn_to_stop(data, session_key, agent_key, agent, stop, ending)
        }
        active = { "spans" => figures["active_spans"], "activity" => figures["active_activity"] }[mode]
        out = { "wall" => figures["wall"], "active" => active }.merge(figures.reject { |key, _| key == "wall" })
        out = out.transform_values { |value| value.is_a?(Float) ? value.round(DECIMALS) : value }
        out.merge("open" => start ? stop.nil? : nil, "active_definition" => mode)
      end

      def spawns(data)
        @spawns[data] ||= data.of_kind("spawn")
      end

      def index(data)
        @indexes[data] ||= data.records.group_by { |record| [record["session_key"], record["agent_key"]] }
      end

      def epoch(ts)
        ts.is_a?(String) ? Time.iso8601(ts).to_f : nil
      end

      def main_spans(life, horizon, stop)
        spans = []
        from = nil
        life.each do |record|
          state = record.dig("body", "state")
          at = epoch(record["ts"])
          next unless at

          if state == "running"
            from ||= at
          elsif %w[waiting_on_user stopped failed].include?(state) && from
            spans << [from, at]
            from = nil
          end
        end
        spans << [from, horizon] if from && stop.nil? && horizon
        spans
      end

      def waiting(life)
        return nil unless life.any? { |record| %w[running waiting_on_user].include?(record.dig("body", "state")) }

        total = 0.0
        from = nil
        life.each do |record|
          state = record.dig("body", "state")
          at = epoch(record["ts"])
          next unless at

          if state == "waiting_on_user"
            from ||= at
          elsif state == "running" && from
            total += at - from
            from = nil
          elsif %w[stopped failed].include?(state) && from
            total += at - from
            from = nil
          end
        end
        total
      end

      def spawn_to_stop(data, session_key, agent_key, agent, stop, ending)
        return nil unless stop

        spawned = spawn_ts(data, session_key, agent_key, agent && agent.dig("body", "spawn_tool_use_id"))
        spawned ? [ending - spawned, 0.0].max : nil
      end

      def spawn_ts(data, session_key, agent_key, tool_use_id)
        record = spawns(data).find do |item|
          item["session_key"] == session_key &&
            ((tool_use_id && item.dig("body", "spawn_tool_use_id") == tool_use_id) || item.dig("body", "child_agent_key") == agent_key)
        end
        record && epoch(record["ts"])
      end

      def activity(records, idle_seconds)
        times = records.filter_map { |record| epoch(record["ts"]) if ACTIVITY_KINDS.include?(record["kind"]) }.uniq.sort
        return nil if times.empty?

        times.each_cons(2).sum(0.0) { |from, to| to - from <= idle_seconds ? to - from : 0.0 }
      end

      def line(time)
        return nil if time.nil?

        parts = []
        parts << "wall #{fmt(time['wall'])}" if time["wall"]
        parts.concat(active_parts(time))
        parts << "wait #{fmt(time['waiting'])}" if time["waiting"]
        parts << "spawn->stop #{fmt(time['spawn_to_stop'])}" if time["spawn_to_stop"]
        parts.empty? ? nil : parts.join(" ")
      end

      def active_parts(time)
        case time["active_definition"]
        when "both"
          [("active spans #{fmt(time['active_spans'])}" if time["active_spans"]),
           ("active activity #{fmt(time['active_activity'])}" if time["active_activity"])].compact
        else
          time["active"] ? ["active #{fmt(time['active'])} (#{time['active_definition']})"] : []
        end
      end

      def fmt(seconds)
        Tellem::Tasks::Totals.format_duration(seconds)
      end
    end
  end
end
