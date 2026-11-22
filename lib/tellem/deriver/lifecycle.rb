# frozen_string_literal: true

require_relative "../ids"

module Tellem
  module Deriver
    module Lifecycle
      MAIN = Ids::MAIN_AGENT
      MAIN_STATES = { "session_start" => "started", "prompt_submit" => "running", "stop" => "waiting_on_user",
                      "session_end" => "stopped" }.freeze
      FINAL = %w[stopped failed].freeze
      TERMINAL_STOPS = %w[end_turn stop_sequence max_tokens refusal].freeze
      IMPORT = "import"

      module_function

      def mark_import(session)
        lasts = session.batches.keys.sort.to_h { |agent| [agent, last_line_at(session.batches[agent])] }
        through = lasts.values.compact.max
        return unless through

        lasts.each do |agent, ts|
          next if ts.nil? || !session.raw[agent].to_a.empty?

          session.add("lifecycle", agent_key: agent, ts: ts, body: {
                        "state" => "stopped", "source_id" => "#{IMPORT}:#{through}", "evidence" => IMPORT, "through" => through
                      })
        end
      end

      def last_line_at(batch)
        times = [batch.started_at]
        batch.exchanges.each do |exchange|
          times << exchange["ts"]
          times << exchange["tool"]["result_at"] if exchange["tool"].is_a?(Hash)
        end
        batch.usage.each { |entry| times.push(entry["ts"], entry["last_line_at"]) }
        times.grep(String).max
      end

      def imported_through(session)
        session.of("lifecycle").filter_map do |record|
          body = record["body"]
          body["through"] if body["evidence"] == IMPORT && body["through"].is_a?(String)
        end.max
      end

      def imported?(session, ts)
        through = imported_through(session)
        !through.nil? && ts.is_a?(String) && ts <= through
      end

      def derive(session)
        session.agent_keys.each do |agent|
          agent == MAIN ? main(session) : subagent(session, agent)
          context(session, agent)
        end
      end

      def state(session, agent, state, source_id, ts)
        session.add("lifecycle", agent_key: agent, ts: ts, body: { "state" => state, "source_id" => source_id })
      end

      def main(session)
        session.raw[MAIN].to_a.each do |record|
          name = MAIN_STATES[record["event"]]
          state(session, MAIN, name, record["id"], record["ts"]) if name
        end
      end

      def subagent(session, agent)
        records = session.raw[agent].to_a
        start = records.find { |record| record["event"] == "subagent_start" }
        state(session, agent, "started", start["id"], start["ts"]) if start
        transcript_started(session, agent) if start_lost?(session, agent)
        running = records.find { |record| record["event"] == "post_tool" }
        state(session, agent, "running", running["id"], running["ts"]) if running
        finals = finals(session, agent)
        return if finals.include?("failed")

        hooked = records.find { |record| record["event"] == "subagent_stop" }
        return hook_stopped(session, agent, hooked, finals) if hooked
        return unless finals.empty?

        failed(session, agent) || stopped(session, agent)
      end

      def start_lost?(session, agent)
        return false unless session.harness == "claude" && session.links[agent]
        return false if session.raw[agent].to_a.any? { |record| record["event"] == "subagent_start" }
        return false if imported?(session, spawn_ts(session.links[agent]))

        session.overdue?(spawn_ts(session.links[agent]))
      end

      def spawn_ts(link)
        call = link["call"]
        return nil unless call

        ts = call["ts"] || call["tool"]["result_at"]
        ts.is_a?(String) ? ts : nil
      end

      def transcript_started(session, agent)
        link = session.links[agent]
        ts = spawn_ts(link)
        return unless ts

        session.add("lifecycle", agent_key: agent, ts: ts,
                                 body: { "state" => "started", "source_id" => link["tool_use_id"], "evidence" => "transcript" })
      end

      def finals(session, agent)
        session.of("lifecycle").filter_map do |record|
          record["body"]["state"] if record["agent_key"] == agent && FINAL.include?(record["body"]["state"])
        end
      end

      def hook_stopped(session, agent, hooked, finals)
        return if finals.empty? && failed(session, agent)

        state(session, agent, "stopped", hooked["id"], hooked["ts"])
      end

      def failed(session, agent)
        link = session.links[agent]
        tool = link && link["call"] && link["call"]["tool"]
        return nil unless tool && tool["is_error"] == true && tool["result_at"].is_a?(String)

        state(session, agent, "failed", link["tool_use_id"], tool["result_at"])
      end

      def stopped(session, agent)
        batch = session.batches[agent]
        last = last_exchange(batch)
        if last && last["role"] == "agent" && last["ts"].is_a?(String) && !pending_tool?(batch)
          handback = handback_at(session, last)
          if handback || turn_over?(session, last)
            parent = session.links.dig(agent, "parent") || MAIN
            later = session.raw[parent].to_a.find { |record| %w[post_tool stop].include?(record["event"]) && record["ts"] > last["ts"] }
            return state(session, agent, "stopped", later["id"], handback || later["ts"]) if later
          end
        end
        ended = session.session_end
        return unless ended

        state(session, agent, "stopped", ended["id"], last && last["ts"].is_a?(String) ? last["ts"] : ended["ts"])
      end

      def handback_at(session, last)
        return nil unless session.harness == "claude" && last["kind"] == "tool"

        tool = last["tool"]
        tool["ends_agent"] == true && tool["result_at"].is_a?(String) ? tool["result_at"] : nil
      end

      def turn_over?(session, last)
        session.harness != "claude" || TERMINAL_STOPS.include?(last["stop_reason"])
      end

      def pending_tool?(batch)
        batch.exchanges.any? { |exchange| exchange["kind"] == "tool" && !exchange.dig("tool", "result_at").is_a?(String) }
      end

      def last_exchange(batch)
        return nil unless batch

        batch.exchanges.each_with_index.max_by { |exchange, index| [exchange["ts"].to_s, index] }&.first
      end

      def context(session, agent)
        last = nil
        timeline(session, agent).each do |ts, source_id, place, model|
          current = [place && place["place_id"], model]
          next if current == last

          last = current
          session.add("context", agent_key: agent, ts: ts, body: {
                        "source_id" => source_id, "model" => model, "effort" => nil, "standing_place_id" => current[0],
                        "branch" => branch(session, place)
                      })
        end
      end

      def timeline(session, agent)
        events = session.standing[agent].map { |ts, place, id| [ts, 0, id, place, nil] }
        batch = session.batches[agent]
        batch&.exchanges&.each_with_index do |exchange, index|
          model = exchange["model"]
          next unless exchange["role"] == "agent" && model.is_a?(String) && !model.empty? && model != "<synthetic>"
          next unless exchange["ts"].is_a?(String)

          events << [exchange["ts"], 1, exchange["request_key"] || "#{agent}:#{index}", nil, model]
        end
        place = nil
        model = nil
        events.sort_by { |ts, order, id, _place, _model| [ts, order, id.to_s] }.map do |ts, _order, id, at, named|
          place = at || place
          model = named || model
          [ts, id, place, model]
        end
      end

      def branch(session, place)
        tree = place && place["resolved"] == "full" ? place.dig("attributes", "worktree_root") : nil
        return nil unless tree.is_a?(String)

        tree_id = session.context.resolve(tree, repository: false)["place_id"]
        sample = session.of("workspace").select { |record| record["body"]["place_id"] == tree_id && record["body"]["status"] == "ok" }
                        .max_by { |record| record["body"]["sampled_at"].to_s }
        sample && sample["body"]["branch"]
      end
    end
  end
end
