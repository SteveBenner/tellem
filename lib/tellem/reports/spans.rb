# frozen_string_literal: true

require "time"
require_relative "../errors"
require_relative "../ids"
require_relative "../otel/report_details"
require_relative "../record/formats"
require_relative "../record/kinds"
require_relative "../record/scope"
require_relative "../tasks/totals"
require_relative "agents"
require_relative "options"
require_relative "records"
require_relative "scan"
require_relative "scopes"
require_relative "tasks"
require_relative "text"
require_relative "tokens"

module Tellem
  module Reports
    module Spans
      USAGE = "tellem spans [--session S] [--task T] [--agent A [--descendants]] [--kind request,tool_call,subagent,turn] " \
              "[--since T] [--until T] [--scope PATH | --all] [--strict] [--no-derive] [--limit N] [--json]"
      KINDS = %w[request tool_call subagent turn].freeze
      DEFAULT_LIMIT = 20_000
      TOKENS = %w[input_tokens output_tokens cache_read_input_tokens cache_creation_input_tokens total_tokens].freeze
      FIELDS = (%w[kind id session_key agent_key parent_agent_key subagent_type model tool task_id start end duration_ms duration_source open is_error] + TOKENS).freeze
      COLUMNS = (%w[id ts session_key agent_key harness request_key model effort cost_usd subagent_type first_line_at] + Record::Kinds::COUNTERS).freeze
      MARK = /"kind":"(?:usage_line|usage_detail|request_start|tool_call|spawn|lifecycle|agent)"/
      MAIN = Ids::MAIN_AGENT
      FINAL_STATES = %w[stopped failed].freeze
      HEADERS = %w[kind rows open total p50 p95 max total_tokens].freeze

      module_function

      def params(options)
        kinds = kinds(options[:kind])
        {
          "session" => options[:session], "task" => options[:task], "agent" => options[:agent],
          "descendants" => options[:descendants] == true, "kind" => kinds,
          "since" => Options.time_bound(options[:since], "--since"), "until" => Options.time_bound(options[:until], "--until"),
          "limit" => limit(options[:limit])
        }
      end

      def kinds(value)
        return KINDS if value.nil?

        list = value.split(",").map(&:strip).reject(&:empty?).uniq
        unknown = list - KINDS
        raise UsageError.new("--kind takes #{KINDS.join(', ')}, not #{unknown.join(', ')}") if list.empty? || !unknown.empty?

        KINDS & list
      end

      def limit(value)
        return DEFAULT_LIMIT if value.nil?

        number = Integer(value, 10)
        raise ArgumentError if number < 1

        number
      rescue ArgumentError
        raise UsageError.new("--limit must be a positive integer, not #{value}")
      end

      def run(scopes, params)
        live = Scopes.live(scopes)
        wanted = wanted_sessions(live, params)
        files = session_files(live, wanted)
        structures = structures(files)
        selection = params["agent"] ? agent_selection(structures, params, files) : nil
        files = files.select { |entry| selection[:sessions].include?(entry[:key]) } if selection
        usage = usage_tuples(files)
        context = Context.new(live, files, structures, usage[:tuples], usage[:index], params)
        rows = context.rows
        rows = filter(rows, params, selection)
        rows.sort_by! { |row| [row["start"] || "~", KINDS.index(row["kind"]), row["id"].to_s] }
        total = rows.size
        [clean(rows.first(params["limit"])), total]
      end

      def wanted_sessions(live, params)
        keys = live.flat_map { |scope| Record::Scope.session_keys(scope["root"]) }.uniq
        spec = params["session"] || (params["agent"] && params["agent"].include?("/") ? params["agent"].split("/", 2).first : nil)
        return keys if spec.nil?

        found = keys.select { |key| key == spec || key.split("-", 2).last == spec }
        if found.empty?
          raise OperationalFailure.new("no session #{spec} in #{live.map { |scope| scope['root'] }.join(', ')}", next_command: "tellem sessions --all")
        end

        found
      end

      def session_files(live, wanted)
        live.flat_map do |scope|
          Records.derived_files(scope["root"]).select { |key, _path| wanted.include?(key) }
                 .map { |key, path| { key: key, path: path, scope_id: scope["scope_id"] } }
        end
      end

      def structures(files)
        out = {}
        files.each do |entry|
          loaded = structure(entry[:path])
          merged = out[entry[:key]] ||= Hash.new { |hash, kind| hash[kind] = [] }
          loaded.each { |kind, list| merged[kind].concat(list) }
        end
        out
      end

      def structure(path)
        records = {}
        superseded = {}
        keep = ->(line) { MARK.match?(line) }
        Records.each_line_record(path, keep: keep) do |record|
          next unless Record::Formats.derived_valid?(record)

          superseded[record["supersedes"]] = true if record["supersedes"]
          records[record["id"]] ||= record
        end
        records.reject { |id, _| superseded[id] }.values.group_by { |record| record["kind"] }
      end

      def usage_tuples(files)
        index = COLUMNS.each_with_index.to_h
        jobs = files.map { |entry| [entry[:scope_id], entry[:path]] }
        results = Scan.run(jobs.map(&:last), COLUMNS)
        Otel::ReportDetails.apply(jobs, results, index)
        { tuples: Tokens.covered_rows(jobs, results, { "session" => nil, "since" => nil, "until" => nil }, index), index: index }
      end

      def agent_selection(structures, params, files)
        spec = params["agent"]
        session_key, agent_key = spec.split("/", 2)
        targets = if agent_key || Ids.valid_session_key?(spec)
                    agent_key ||= MAIN
                    unless Ids.valid_session_key?(session_key) && Ids.valid_agent_key?(agent_key)
                      raise UsageError.new("#{spec} is not a valid agent; #{Agents::USAGE}")
                    end

                    [[session_key, agent_key]]
                  else
                    key = Ids.agent_key(spec)
                    raise UsageError.new("#{spec} is not a valid agent; #{Agents::USAGE}") unless key && key == spec

                    structures.keys.select { |session| agent_map(structures[session]).key?(key) }.map { |session| [session, key] }
                  end
        if targets.empty? || targets.any? { |session, _| !structures.key?(session) }
          raise OperationalFailure.new("no agent #{spec} in the selected sessions", next_command: "tellem sessions --all")
        end
        if targets.size > 1
          raise OperationalFailure.new("#{spec} matches #{targets.size} agents", next_command: "tellem spans --agent SESSION_KEY/#{spec}")
        end

        picked = {}
        targets.each do |session, agent|
          keys = params["descendants"] ? Agents.descendants(agent_map(structures[session]), agent) : [agent]
          keys.each { |key| picked[[session, key]] = true }
        end
        { picked: picked, sessions: files.map { |entry| entry[:key] }.uniq & targets.map(&:first) }
      end

      def agent_map(structure)
        out = {}
        structure["agent"].to_a.sort_by { |record| Records.sort_key(record) }.each do |record|
          body = record["body"] || {}
          out[record["agent_key"]] = { "agent_key" => record["agent_key"], "parent_agent_key" => body["parent_agent_key"],
                                       "agent_type" => body["agent_type"], "model" => body["model"] }
        end
        structure["spawn"].to_a.each do |record|
          body = record["body"] || {}
          child = body["child_agent_key"]
          next unless child.is_a?(String)

          entry = out[child] ||= { "agent_key" => child, "parent_agent_key" => nil, "agent_type" => nil, "model" => nil }
          entry["parent_agent_key"] ||= body["parent_agent_key"]
          entry["agent_type"] ||= body["requested_type"]
        end
        out
      end

      def filter(rows, params, selection)
        task = params["task"]
        since = params["since"]
        before = params["until"]
        rows.select do |row|
          next false if selection && !selection[:picked].key?([row["session_key"], row["agent_key"]])
          next false if task && (task == Tasks::UNATTRIBUTED ? !row["task_id"].nil? : row["task_id"] != task)

          at = row["start"] || row["end"]
          next false if (since || before) && at.nil?
          next false if since && at < since
          next false if before && at >= before

          true
        end
      end

      def text(rows, total)
        table = KINDS.filter_map do |kind|
          mine = rows.select { |row| row["kind"] == kind }
          next if mine.empty?

          durations = mine.filter_map { |row| row["duration_ms"] }.sort
          tokens = mine.filter_map { |row| row["total_tokens"] }
          [kind, mine.size.to_s, mine.count { |row| row["open"] }.to_s, durations.empty? ? "-" : format_ms(durations.sum),
           format_ms(percentile(durations, 0.5)), format_ms(percentile(durations, 0.95)), format_ms(durations.last),
           tokens.empty? ? "-" : tokens.sum.to_s]
        end
        body = Text.table(HEADERS, table)
        rows.size < total ? "#{body}\ntruncated: #{rows.size} of #{total} rows" : body
      end

      def percentile(sorted, fraction)
        return nil if sorted.empty?

        sorted[[(fraction * sorted.size).ceil - 1, 0].max]
      end

      def format_ms(value)
        return "-" if value.nil?
        return "#{value}ms" if value < 1000
        return format("%.1fs", value / 1000.0) if value < 60_000

        Tellem::Tasks::Totals.format_duration(value / 1000)
      end

      class Context
        def initialize(scopes, files, structures, tuples, index, params)
          @scopes = scopes
          @files = files
          @structures = structures
          @tuples = tuples
          @index = index
          @params = params
          @kinds = params["kind"]
          @agents = structures.transform_values { |structure| Spans.agent_map(structure) }
          @matcher = nil
          @tasks = []
          load_tasks
        end

        def rows
          requests = request_rows
          out = []
          out.concat(requests) if @kinds.include?("request")
          out.concat(tool_rows) if @kinds.include?("tool_call")
          out.concat(subagent_rows(requests)) if @kinds.include?("subagent")
          out.concat(turn_rows(requests)) if @kinds.include?("turn")
          out
        end

        private

        def load_tasks
          active = Tasks.active_scopes_quiet(@scopes)
          return if active.empty?

          tasks = Tasks.load_tasks(active)
          session = @params["session"]
          if session
            ids = @files.map { |entry| Tasks.session_id(entry[:key]) }.uniq
            tasks = tasks.select { |task| (task["sessions"] & ids).any? }
          end
          @tasks = tasks
          @matcher = Tasks::Matcher.new(active, tasks)
        end

        def task_id(session_key, agent_key, ts)
          return nil if @matcher.nil?

          @matcher.task_for(session_key, agent_key, ts)&.fetch("id")
        end

        def blank
          FIELDS.to_h { |field| [field, nil] }
        end

        def value(tuple, name)
          tuple[@index.fetch(name)]
        end

        def request_rows
          @request_rows ||= @tuples.map { |tuple| request(tuple) }
        end

        def request(tuple)
          session_key = value(tuple, "session_key")
          agent_key = value(tuple, "agent_key")
          harness = value(tuple, "harness")
          request_key = value(tuple, "request_key")
          structure = @structures[session_key]
          ended = last_line(structure, harness, request_key) || value(tuple, "ts")
          first = value(tuple, "first_line_at") || value(tuple, "ts")
          duration, started, source = request_duration(structure, harness, request_key, ended)
          row = blank
          row.merge!(
            "kind" => "request", "id" => request_key, "session_key" => session_key, "agent_key" => agent_key,
            "parent_agent_key" => parent(session_key, agent_key), "subagent_type" => value(tuple, "subagent_type"),
            "model" => value(tuple, "model"), "task_id" => task_id(session_key, agent_key, value(tuple, "ts")),
            "start" => started || first, "end" => ended, "duration_ms" => duration, "duration_source" => source, "open" => false
          )
          TOKENS.each { |name| row[name] = value(tuple, name) }
          row.merge!("_ts" => value(tuple, "ts"), "_first" => first)
        end

        def last_line(structure, harness, request_key)
          lines = (@lines ||= {})[structure.object_id] ||= begin
            map = {}
            structure["usage_line"].to_a.each do |record|
              body = record["body"] || {}
              key = [body["harness"], body["request_key"]]
              map[key] = body["line_at"] if body["line_at"].is_a?(String) && (map[key].nil? || body["line_at"] > map[key])
            end
            map
          end
          lines[[harness, request_key]]
        end

        def recorded_start(structure, harness, request_key)
          starts = (@starts ||= {})[structure.object_id] ||= structure["request_start"].to_a.to_h do |record|
            [[record.dig("body", "harness"), record.dig("body", "request_key")], record.dig("body", "started_at")]
          end
          starts[[harness, request_key]]
        end

        def otel_duration(structure, harness, request_key)
          details = (@details ||= {})[structure.object_id] ||= begin
            map = {}
            structure["usage_detail"].to_a.sort_by { |record| [record["ts"].to_s, record["id"]] }.each do |record|
              body = record["body"] || {}
              key = [body["harness"], body["request_key"]]
              map[key] ||= body["duration_ms"] if body["duration_ms"].is_a?(Integer)
            end
            map
          end
          details[[harness, request_key]]
        end

        def request_duration(structure, harness, request_key, ended)
          otel = otel_duration(structure, harness, request_key)
          if otel && ended
            started = clock(ended)
            return [otel, started && stamp(started - (otel / 1000.0)), "otel"]
          end
          began = recorded_start(structure, harness, request_key)
          return [nil, nil, "none"] unless began && ended

          start_time = clock(began)
          end_time = clock(ended)
          return [nil, nil, "none"] unless start_time && end_time

          [[((end_time - start_time) * 1000).round, 0].max, began, "transcript"]
        end

        def parent(session_key, agent_key)
          @agents.dig(session_key, agent_key, "parent_agent_key")
        end

        def tool_rows
          @structures.flat_map do |session_key, structure|
            structure["tool_call"].to_a.map do |record|
              body = record["body"] || {}
              agent_key = body["agent_key"] || record["agent_key"]
              info = @agents.dig(session_key, agent_key) || {}
              row = blank
              row.merge!(
                "kind" => "tool_call", "id" => body["tool_use_id"], "session_key" => session_key, "agent_key" => agent_key,
                "parent_agent_key" => info["parent_agent_key"], "subagent_type" => info["agent_type"], "tool" => body["tool"],
                "task_id" => task_id(session_key, agent_key, body["started_at"] || body["ended_at"]),
                "start" => body["started_at"], "end" => body["ended_at"], "duration_ms" => body["duration_ms"],
                "duration_source" => body["duration_ms"] ? "transcript" : "none", "open" => false, "is_error" => body["is_error"]
              )
            end
          end
        end

        def sums(rows)
          sum = TOKENS.to_h { |name| [name, 0] }
          rows.each { |row| TOKENS.each { |name| sum[name] += row[name].to_i } }
          sum
        end

        def subagent_rows(requests)
          by_agent = requests.group_by { |row| [row["session_key"], row["agent_key"]] }
          @structures.flat_map do |session_key, structure|
            calls = structure["tool_call"].to_a.to_h { |record| [record.dig("body", "tool_use_id"), record["body"]] }
            spawns = structure["spawn"].to_a.to_h { |record| [record.dig("body", "child_agent_key"), record] }
            states = structure["lifecycle"].to_a.group_by { |record| record["agent_key"] }
            @agents[session_key].keys.reject { |agent_key| agent_key == MAIN }.sort.map do |agent_key|
              subagent(session_key, agent_key, @agents[session_key][agent_key], spawns[agent_key], states[agent_key].to_a, calls, by_agent)
            end
          end
        end

        def subagent(session_key, agent_key, info, spawn, states, calls, by_agent)
          spawn_at = spawn && (calls.dig(spawn.dig("body", "spawn_tool_use_id"), "started_at") || spawn["ts"])
          started = (states.select { |record| record.dig("body", "state") == "started" }.map { |record| record["ts"] } + [spawn_at].compact).min
          finals = states.select { |record| FINAL_STATES.include?(record.dig("body", "state")) }
          final = finals.max_by { |record| [record["ts"].to_s, record["id"]] }
          ended = final && final["ts"]
          duration = started && ended ? [((clock(ended) - clock(started)) * 1000).round, 0].max : nil
          row = blank
          row.merge!(
            "kind" => "subagent", "id" => agent_key, "session_key" => session_key, "agent_key" => agent_key,
            "parent_agent_key" => info["parent_agent_key"], "subagent_type" => info["agent_type"], "model" => info["model"],
            "task_id" => task_id(session_key, agent_key, started), "start" => started, "end" => ended,
            "duration_ms" => duration, "duration_source" => duration ? "lifecycle" : "none", "open" => ended.nil?,
            "is_error" => final ? final.dig("body", "state") == "failed" : nil
          )
          row.merge!(sums(by_agent[[session_key, agent_key]].to_a))
        end

        def turn_rows(requests)
          return [] if @matcher.nil?

          keys = @files.map { |entry| entry[:key] }.uniq.to_h { |key| [Tasks.session_id(key), key] }
          inside = Hash.new { |hash, key| hash[key] = [] }
          requests.each do |row|
            task = @matcher.task_for(row["session_key"], row["agent_key"], row["_ts"])
            next unless task

            position = @matcher.turn_for(row["session_key"], task, row["_ts"])
            inside[[task["id"], row["session_key"], position]] << row unless position.nil?
          end
          @tasks.flat_map do |task|
            task["turns"].each_with_index.filter_map do |turn, position|
              session_key = keys[turn["session_id"]]
              next unless session_key && turn["at"].is_a?(Numeric)

              turn_row(task, turn, position, session_key, inside[[task["id"], session_key, position]])
            end
          end
        end

        def turn_row(task, turn, position, session_key, inside)
          spans = Array(turn["spans"])
          open = spans.empty? || spans.any? { |span| span[1].nil? }
          ended = open ? nil : spans.map { |span| span[1] }.max
          row = blank
          row.merge!(
            "kind" => "turn", "id" => "#{task['id']}:#{position}", "session_key" => session_key, "agent_key" => MAIN,
            "task_id" => task["id"], "start" => Spans.stamp(turn["at"]), "end" => ended && Spans.stamp(ended),
            "duration_ms" => ended ? [((ended - turn["at"]) * 1000).round, 0].max : nil,
            "duration_source" => ended ? "task" : "none", "open" => open
          )
          row.merge!(sums(inside))
        end

        def clock(ts)
          Time.iso8601(ts.to_s).to_f
        rescue ArgumentError
          nil
        end

        def stamp(time)
          Spans.stamp(time)
        end
      end

      def stamp(time)
        Time.at(time).utc.strftime(Tasks::STAMP)
      end

      def clean(rows)
        rows.map { |row| row.slice(*FIELDS) }
      end
    end
  end
end
