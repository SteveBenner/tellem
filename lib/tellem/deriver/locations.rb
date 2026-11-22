# frozen_string_literal: true

require_relative "../ids"
require_relative "../record/reader"

module Tellem
  module Deriver
    module Locations
      module_function

      def derive(session)
        session.agent_keys.each do |agent|
          observations = session.raw[agent].to_a
          observations.each do |record|
            place = session.local_place(record["cwd"], agent_key: agent, ts: record["ts"])
            next unless place

            session.standing[agent] << [record["ts"], place, record["id"]]
            session.home[agent] ||= place
          end
          session.home[agent] ||= transcript_home(session, agent)
          intervals(session, agent).each { |run| stands_in(session, agent, run) }
        end
      end

      def transcript_home(session, agent)
        batch = session.batches[agent]
        return nil unless batch

        cwd, ts = line_cwd(session, agent, batch) || tool_cwd(batch)
        cwd && session.local_place(cwd, agent_key: agent, ts: ts || batch.started_at || session.first_ts)
      end

      def line_cwd(session, agent, batch)
        entry = batch.usage.find { |item| absolute?(item["cwd"]) }
        return [entry["cwd"], entry["ts"]] if entry

        path = session.natives.dig(agent, "path")
        return nil unless session.harness == "claude" && path.is_a?(String)

        Record::Reader.each(path) { |line| return [line["cwd"], batch.started_at] if absolute?(line["cwd"]) }
        nil
      end

      def tool_cwd(batch)
        exchange = batch.exchanges.find { |item| item["kind"] == "tool" && item.dig("tool", "cwd").is_a?(String) }
        exchange && [exchange.dig("tool", "cwd"), exchange["ts"]]
      end

      def absolute?(path)
        path.is_a?(String) && path.start_with?("/")
      end

      def intervals(session, agent)
        entries = session.standing[agent]
        events = session.raw[agent].to_a.to_h { |record| [record["id"], record["event"]] }
        runs = []
        entries.each do |entry|
          previous = runs.last&.last
          if previous.nil? || boundary?(session, agent, previous, entry, events)
            runs << [entry]
          else
            runs.last << entry
          end
        end
        runs.each_with_index.select { |run, index| closed?(session, agent, run, index == runs.size - 1, events) }.map(&:first)
      end

      def boundary?(session, agent, previous, entry, events)
        return true if previous[1]["place_id"] != entry[1]["place_id"]
        return true if Session::STOP_EVENTS.include?(events[previous[2]])
        return false if agent == Ids::MAIN_AGENT

        session.stops.any? { |stop| stop > previous[0] && stop <= entry[0] }
      end

      def closed?(session, agent, run, last, events)
        return true unless last
        return true if Session::STOP_EVENTS.include?(events[run.last[2]])
        return false if agent == Ids::MAIN_AGENT

        session.stops.any? { |stop| stop > run.last[0] }
      end

      def stands_in(session, agent, run)
        first = run.first
        session.add("stands_in", agent_key: agent, ts: first[0], body: {
                      "place_id" => first[1]["place_id"], "first_raw_id" => first[2], "from" => first[0], "to" => run.last[0]
                    })
      end
    end
  end
end
