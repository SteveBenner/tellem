# frozen_string_literal: true

require "json"
require "time"
require_relative "../config/resolver"
require_relative "../errors"
require_relative "../ids"
require_relative "../tasks/engine"
require_relative "context"
require_relative "cursor"
require_relative "sources"
require_relative "transcripts"

module Tellem
  module Deriver
    module Tasks
      MAIN = Ids::MAIN_AGENT
      MODES = %w[on].freeze
      GAP_CAUSE = "task_no_prompt_text"
      RETIRED = "retired"
      PROMPT_SOURCES = [nil, "queued"].freeze
      FINAL_STATES = %w[stopped failed].freeze
      TS_FORMAT = "%Y-%m-%dT%H:%M:%S.%LZ"
      COMMAND_NAME = %r{<command-name>\s*(.*?)\s*</command-name>}m.freeze
      COMMAND_ARGS = %r{<command-args>(.*?)</command-args>}m.freeze
      LOCAL_OUTPUT = /\A\s*<local-command-(?:stdout|stderr|caveat)>/.freeze
      INTERRUPT = /\A\s*\[Request interrupted by user/.freeze
      PAIR_WINDOW_S = 10.0
      RANK = { "session_start" => 0, "system_prompt" => 1, "prompt" => 1, "subagent_start" => 2, "tool" => 3, "subagent_stop" => 4, "stop" => 5, "session_end" => 6 }.freeze

      module_function

      def mode(root)
        Config.get("tasks.mode", scope: root)
      end

      def derive(root, totals)
        return totals unless MODES.include?(mode(root))

        context = Context.new(root)
        sessions = load(context)
        return totals if sessions.empty?

        engine = replay(context, sessions)
        write(sessions, engine, totals)
        totals
      end

      def load(context)
        Record::Scope.session_keys(context.root).filter_map do |key|
          session = Session.new(context, key)
          Sources.load_raw(session)
          native = Sources.discover(context, session.harness, session.session_id, Sources.main_path(session), session: session)[MAIN]
          session.natives[MAIN] = native if native
          ingest(context, session) if native
          session
        end
      end

      def ingest(context, session)
        reader = context.seam(Transcripts::INGEST.fetch(session.harness))
        Transcripts.read(session, reader, MAIN)
      rescue CapabilityUnavailable
        nil
      end

      def replay(context, sessions)
        engine = Tellem::Tasks::Engine.new(rules: Config.tasks_rules, system_prompts: Config.tasks_system_prompts)
        events = sessions.flat_map { |session| Events.for(context, session) }
        events.sort_by { |event| [event[:time], event[:key], event[:seq]] }.each do |event|
          engine.feed(event[:payload])
        end
        sessions.each { |session| missing(session) unless prompts?(session) }
        engine
      end

      def prompts?(session)
        batch = session.batches[MAIN]
        !batch.nil? && batch.exchanges.any? { |exchange| Events.prompt?(exchange) }
      end

      def missing(session)
        reason = session.batches[MAIN] ? "no_prompt_in_transcript" : "no_transcript"
        session.gap(GAP_CAUSE, "tasks/#{session.key}", agent_key: MAIN, ts: session.first_ts || Record::FS.rfc3339_ms(0),
                                                       detail: { "reason" => reason })
      end

      def write(sessions, engine, totals)
        by_id = sessions.to_h { |session| [session.session_id, session] }
        engine.tasks.each do |task|
          home = by_id[task["sessions"].first] || sessions.first
          state(home, task)
        end
        retire(sessions, engine.tasks.map { |task| task["id"] })
        sessions.each { |session| totals.absorb(session.flush) }
      end

      def retire(sessions, live)
        sessions.each do |session|
          records = session.of("task")
          replaced = records.filter_map { |record| record["supersedes"] }
          records.reject { |record| replaced.include?(record["id"]) }.each do |tip|
            body = tip["body"]
            next if live.include?(body["id"]) || body["merged_into"]

            task = body.reject { |key, _| key == "state_digest" }.merge("merged_into" => RETIRED)
            session.add("task", agent_key: MAIN, ts: tip["ts"], body: task.merge("state_digest" => Ids.sha256(JSON.generate(task))[0, 32]),
                                supersedes: tip["id"])
          end
        end
      end

      def state(session, task)
        digest = Ids.sha256(JSON.generate(task))[0, 32]
        id = task["id"]
        chain = session.of("task").select { |record| record["body"]["id"] == id }
        replaced = chain.filter_map { |record| record["supersedes"] }
        tip = chain.reject { |record| replaced.include?(record["id"]) }.last
        session.add("task", agent_key: MAIN, ts: stamp(task["last_activity"]), body: task.merge("state_digest" => digest),
                            supersedes: tip && tip["id"])
      end

      def stamp(epoch)
        Time.at(epoch).utc.strftime(TS_FORMAT)
      end

      module Events
        module_function

        def for(context, session)
          batch = session.batches[MAIN]
          standing = standing(session, batch)
          list = []
          raw(session, list)
          prompts(session, batch, list)
          tools(session, batch, list)
          subagents(session, list)
          ordered = list.sort_by.with_index { |item, index| [item[:time], RANK.fetch(item[:payload]["type"]), index] }
          ordered.each_with_index.map do |item, seq|
            payload = item[:payload].merge("session_id" => session.session_id, "repo" => repo(context, session, standing, item[:time]))
            { time: item[:time], key: session.key, seq: seq, payload: payload.merge("cwd" => payload["repo"]) }
          end
        end

        def clock(ts)
          Time.iso8601(ts).to_f
        rescue ArgumentError
          nil
        end

        def prompt?(exchange)
          exchange["role"] == "user" && exchange["kind"] == "text" && PROMPT_SOURCES.include?(exchange["source"]) && exchange["text"].is_a?(String)
        end

        def prompt_text(text)
          name = COMMAND_NAME.match(text)
          return text unless name

          args = COMMAND_ARGS.match(text)
          [name[1], args && args[1].strip].compact.reject(&:empty?).join(" ")
        end

        def raw(session, list)
          session.raw[MAIN].to_a.each do |record|
            time = clock(record["ts"])
            next unless time

            case record["event"]
            when "session_start" then list << { time: time, payload: { "type" => "session_start", "time" => time, "source" => record["start_source"] } }
            when "session_end" then list << { time: time, payload: { "type" => "session_end", "time" => time } }
            when "stop" then list << { time: time, payload: { "type" => "stop", "time" => time, "last_assistant_message" => last_message(session, record["ts"]) } }
            end
          end
        end

        def last_message(session, ts)
          batch = session.batches[MAIN]
          return nil unless batch

          found = batch.exchanges.select { |exchange| exchange["role"] == "agent" && exchange["kind"] == "text" && exchange["ts"].to_s <= ts }.max_by { |exchange| exchange["ts"].to_s }
          found && found["text"]
        end

        def prompts(session, batch, list)
          submitted = session.raw[MAIN].to_a.select { |record| record["event"] == "prompt_submit" }.filter_map { |record| clock(record["ts"]) }
          used = {}
          texts(batch).each do |time, text|
            index = submitted.each_index.reject { |i| used[i] }.min_by { |i| (submitted[i] - time).abs }
            paired = !index.nil? && (submitted[index] - time).abs <= PAIR_WINDOW_S
            used[index] = true if paired
            at = paired ? submitted[index] : time
            list << { time: at, payload: { "type" => "prompt", "time" => at, "prompt" => text, "entrypoint" => nil } }
          end
          submitted.each_with_index do |time, index|
            list << { time: time, payload: { "type" => "system_prompt", "time" => time } } unless used[index]
          end
        end

        def texts(batch)
          return [] unless batch

          found = []
          list = batch.exchanges
          list.each_with_index do |exchange, index|
            next unless prompt?(exchange)

            text = exchange["text"]
            time = clock(exchange["ts"])
            next if time.nil? || LOCAL_OUTPUT.match?(text) || INTERRUPT.match?(text)
            next if COMMAND_NAME.match?(text) && list[index + 1..index + 2].to_a.any? { |after| prompt?(after) && LOCAL_OUTPUT.match?(after["text"]) }

            found << [time, prompt_text(text)]
          end
          found
        end

        def tools(_session, batch, list)
          return unless batch

          batch.exchanges.each do |exchange|
            tool = exchange["tool"]
            next unless exchange["kind"] == "tool" && tool.is_a?(Hash)

            time = clock(tool["result_at"] || exchange["ts"])
            next unless time

            input = tool["input"].is_a?(Hash) ? tool["input"] : {}
            list << { time: time, payload: { "type" => "tool", "time" => time, "tool_name" => tool["name"], "tool_input" => input } }
          end
        end

        def subagents(session, list)
          types = session.of("agent").to_h { |record| [record["agent_key"], record["body"]["agent_type"]] }
          session.of("lifecycle").group_by { |record| record["agent_key"] }.each do |agent, records|
            next if agent == MAIN

            start = records.select { |record| record["body"]["state"] == "started" }.map { |record| record["ts"] }.min
            stop = records.select { |record| FINAL_STATES.include?(record["body"]["state"]) }.map { |record| record["ts"] }.max
            began = start && clock(start)
            next unless began

            list << { time: began, payload: { "type" => "subagent_start", "time" => began, "agent_id" => agent, "agent_type" => types[agent] } }
            ended = stop && clock(stop)
            list << { time: ended, payload: { "type" => "subagent_stop", "time" => ended, "agent_id" => agent, "agent_type" => types[agent] } } if ended
          end
        end

        def standing(session, batch)
          points = session.raw[MAIN].to_a.filter_map { |record| point(record["ts"], record["cwd"]) }
          if batch
            points.concat(batch.usage.filter_map { |entry| point(entry["ts"], entry["cwd"]) })
            points.concat(batch.exchanges.filter_map { |exchange| exchange["tool"].is_a?(Hash) ? point(exchange["ts"], exchange["tool"]["cwd"]) : nil })
          end
          points.sort_by { |time, cwd| [time, cwd] }
        end

        def point(ts, cwd)
          return nil unless ts.is_a?(String) && cwd.is_a?(String) && cwd.start_with?("/")

          time = clock(ts)
          time && [time, cwd]
        end

        def repo(context, session, standing, time)
          found = standing.reverse.find { |point_time, _cwd| point_time <= time } || standing.first
          return "" unless found

          quick = context.resolve(found[1], repository: false)
          place = session.place_for(quick["place_id"])
          tree = place && place.dig("attributes", "worktree_root")
          tree || (place && place["real_path"]) || quick["real_path"] || found[1]
        end
      end
    end
  end
end
