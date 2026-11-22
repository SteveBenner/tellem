# frozen_string_literal: true

require "time"
require_relative "../config/resolver"
require_relative "../errors"
require_relative "../ids"
require_relative "../record/formats"
require_relative "../record/scope"
require_relative "../tasks/parity"
require_relative "../tasks/totals"
require_relative "command"
require_relative "records"
require_relative "scopes"
require_relative "text"
require_relative "tokens"

module Tellem
  module Reports
    module Tasks
      USAGE = "tellem tasks [--session S] [--since T] [--scope PATH | --all] [--strict] [--no-derive] [--json]"
      MODES = %w[on].freeze
      MODE_NEXT = "tellem config set tasks.mode on"
      TASK_MARK = '"kind":"task"'
      MAIN = Ids::MAIN_AGENT
      UNATTRIBUTED = "unattributed"
      STAMP = "%Y-%m-%dT%H:%M:%S.%LZ"
      MINUTE = 60.0
      HEADERS = %w[id name repository started elapsed active agents subagents requests total_tokens output_tokens
                   total_tokens_per_agent_min output_tokens_per_agent_min].freeze
      DURATIONS = %w[elapsed active agents].freeze
      RATES = %w[total_tokens_per_agent_min output_tokens_per_agent_min].freeze

      module_function

      def run(context)
        options, _rest, scopes, derive = Command.prepare(context, usage: USAGE, values: %w[--session --since])
        params = Tokens.params(by: "agent,session", session: options[:session], since: options[:since])
        rows = report(scopes, params, [])
        filters = params.reject { |key, value| key == "by" || value.nil? }
        data = Command.envelope(scopes, derive, "filters" => filters, "rows" => rows)
        Command.result(data, text(rows, []), derive, ["source: files"])
      end

      def active_scopes(scopes)
        live = Scopes.live(scopes)
        active = live.select { |scope| MODES.include?(Config.get("tasks.mode", scope: scope["root"])) }
        return active unless active.empty?

        raise OperationalFailure.new("tasks.mode is off for every covered scope, so no task is derived", next_command: MODE_NEXT)
      end

      def active_scopes_quiet(scopes)
        Scopes.live(scopes).select { |scope| MODES.include?(Config.get("tasks.mode", scope: scope["root"])) }
      end

      def report(scopes, params, dims)
        active = active_scopes(scopes)
        tasks = load_tasks(active)
        session = params["session"]
        if session
          sid = session_id(session)
          tasks = tasks.select { |task| task["sessions"].include?(sid) }
        end
        pairs, index = attribute(active, tasks, params)
        build(tasks, pairs, index, dims)
      end

      def tokens_report(scopes, by: nil, session: nil, since: nil, until_time: nil)
        dims = by.nil? ? [] : Backends::Reports.dimensions({ "by" => by })
        raise UsageError.new("--tasks combines only with --by agent") unless dims.empty? || dims == ["agent"]

        params = Tokens.params(by: "agent,session", session: session, since: since, until_time: until_time)
        [report(scopes, params, dims), dims, params]
      end

      def session_breakdown(scopes, session: nil)
        active = active_scopes_quiet(scopes)
        return nil if active.empty?

        tasks = load_tasks(active)
        params = Tokens.params(by: "agent,session", session: session)
        pairs, index = attribute(active, tasks, params)
        out = {}
        pairs.each do |tuple, task|
          next if task.nil?

          cell = ((out[tuple[index["session_key"]]] ||= {})[tuple[index["agent_key"]]] ||= {})[task["id"]] ||= { "total_tokens" => 0, "output_tokens" => 0 }
          cell["total_tokens"] += tuple[index["total_tokens"]].to_i
          cell["output_tokens"] += tuple[index["output_tokens"]].to_i
        end
        out
      end

      def cells(breakdown, session_key, agent_key = nil)
        agents = breakdown[session_key] || {}
        picked = agent_key ? agents.slice(agent_key) : agents
        merged = {}
        picked.each_value do |by_task|
          by_task.each do |id, counters|
            sum = merged[id] ||= { "id" => id, "total_tokens" => 0, "output_tokens" => 0 }
            sum["total_tokens"] += counters["total_tokens"]
            sum["output_tokens"] += counters["output_tokens"]
          end
        end
        merged.values.sort_by { |item| item["id"] }
      end

      def cell_text(items)
        items.empty? ? "-" : items.map { |item| "#{item['id']} (#{item['total_tokens']})" }.join(", ")
      end

      def session_id(session_key)
        session_key.to_s.split("-", 2).last
      end

      def load_tasks(scopes)
        scopes.flat_map { |scope| scope_tasks(scope) }.uniq { |task| task["id"] }.sort_by { |task| [task["started"], task["id"]] }
      end

      def scope_tasks(scope)
        seen = {}
        list = []
        superseded = {}
        keep = ->(line) { line.include?(TASK_MARK) }
        Records.derived_files(scope["root"]).each do |_key, path|
          Records.each_line_record(path, keep: keep) do |record|
            next unless record["kind"] == "task" && Record::Formats.derived_valid?(record)

            superseded[record["supersedes"]] = true if record["supersedes"]
            next if seen[record["id"]]

            seen[record["id"]] = true
            list << record
          end
        end
        list.reject { |record| superseded[record["id"]] }.map { |record| record["body"] }
            .select { |body| Tellem::Tasks::Parity.usable?(body) && !body["merged_into"] }
      end

      def attribute(active, tasks, params)
        rows, index = Tokens.request_rows(active, params)
        matcher = Matcher.new(active, tasks)
        session = index.fetch("session_key")
        agent = index.fetch("agent_key")
        ts = index.fetch("ts")
        pairs = rows.map { |tuple| [tuple, matcher.task_for(tuple[session], tuple[agent], tuple[ts])] }
        [pairs, index]
      end

      def build(tasks, pairs, index, dims)
        groups = {}
        agent = index.fetch("agent_key")
        total = index.fetch("total_tokens")
        output = index.fetch("output_tokens")
        pairs.each do |tuple, task|
          key = [task && task["id"], dims.empty? ? nil : tuple[agent]]
          group = groups[key] ||= { "requests" => 0, "total_tokens" => 0, "output_tokens" => 0 }
          group["requests"] += 1
          group["total_tokens"] += tuple[total].to_i
          group["output_tokens"] += tuple[output].to_i
        end
        now = Time.now.to_f
        rules = Config.tasks_rules
        rows = tasks.flat_map do |task|
          mine = groups.select { |(id, _), _| id == task["id"] }
          mine = { [task["id"], nil] => { "requests" => 0, "total_tokens" => 0, "output_tokens" => 0 } } if mine.empty?
          mine.sort_by { |(_, who), _| who.to_s.b }.map { |(_, who), group| task_row(task, who, group, now, rules, dims) }
        end
        rest = groups.select { |(id, _), _| id.nil? }
        rest = { [nil, nil] => { "requests" => 0, "total_tokens" => 0, "output_tokens" => 0 } } if rest.empty?
        rows + rest.sort_by { |(_, who), _| who.to_s.b }.map { |(_, who), group| unattributed_row(who, group, dims) }
      end

      def task_row(task, who, group, now, rules, dims)
        values = Tellem::Tasks::Totals.totals(task, now, rules)
        row = {}
        row["id"] = task["id"]
        row["agent"] = who if dims.any?
        row.merge!(
          "name" => task["name"], "repository" => task["repo"], "started" => Time.at(task["started"]).utc.strftime(STAMP),
          "elapsed" => values[:elapsed].round(3), "active" => values[:active].round(3), "agents" => values[:agents].round(3),
          "subagents" => values[:subagents], "requests" => group["requests"], "total_tokens" => group["total_tokens"],
          "output_tokens" => group["output_tokens"],
          "total_tokens_per_agent_min" => rate(group["total_tokens"], values[:agents]),
          "output_tokens_per_agent_min" => rate(group["output_tokens"], values[:agents])
        )
      end

      def unattributed_row(who, group, dims)
        row = { "id" => UNATTRIBUTED }
        row["agent"] = who if dims.any?
        row.merge("name" => nil, "repository" => nil, "started" => nil, "elapsed" => nil, "active" => nil, "agents" => nil, "subagents" => nil,
                  "requests" => group["requests"], "total_tokens" => group["total_tokens"], "output_tokens" => group["output_tokens"],
                  "total_tokens_per_agent_min" => nil, "output_tokens_per_agent_min" => nil)
      end

      def rate(count, seconds)
        return nil if seconds < MINUTE

        (count / (seconds / MINUTE)).round(2)
      end

      def text(rows, dims)
        headers = [HEADERS.first] + dims + HEADERS.drop(1)
        table = rows.map do |row|
          headers.map do |name|
            value = row[name]
            if value.nil? then "-"
            elsif DURATIONS.include?(name) then Tellem::Tasks::Totals.format_duration(value)
            elsif RATES.include?(name) then format("%.1f", value)
            else value.to_s
            end
          end
        end
        Text.table(headers, table)
      end

      class Matcher
        def initialize(active, tasks)
          @modes = {}
          active.each do |scope|
            mode = Config.get("tasks.attribution", scope: scope["root"])
            Record::Scope.session_keys(scope["root"]).each { |key| @modes[key] ||= mode }
          end
          @default = Config.get("tasks.attribution")
          @turns = Hash.new { |hash, key| hash[key] = [] }
          @agents = {}
          tasks.each { |task| index(task) }
          @turns.each_value { |list| list.sort_by! { |turn| turn[0] } }
        end

        def task_for(session_key, agent_key, ts)
          sid = Tasks.session_id(session_key)
          if agent_key != MAIN
            task = @agents[[sid, agent_key]]
            return task if task
          end
          time = clock(ts)
          return nil if time.nil?

          turns = @turns[sid]
          spans = (@modes[session_key] || @default) == "spans"
          found = turns.reverse_each.find { |at, list, _| at <= time && (!spans || covered?(list, time)) }
          found && found[2]
        end

        def turn_for(session_key, task, ts)
          time = clock(ts)
          return nil if time.nil?

          found = @turns[Tasks.session_id(session_key)].reverse_each.find { |at, _list, owner, _position| owner.equal?(task) && at <= time }
          found && found[3]
        end

        private

        def index(task)
          task["turns"].each_with_index do |turn, position|
            @turns[turn["session_id"]] << [turn["at"], turn["spans"], task, position] if turn["session_id"].is_a?(String) && turn["at"].is_a?(Numeric)
          end
          task["subagents"].each do |agent|
            next unless agent["agent_id"].is_a?(String)

            @agents[[agent["session_id"], agent["agent_id"]]] ||= task
          end
        end

        def covered?(spans, time)
          spans.any? { |span| span[0] <= time && (span[1].nil? || time <= span[1]) }
        end

        def clock(ts)
          Time.iso8601(ts.to_s).to_f
        rescue ArgumentError
          nil
        end
      end
    end
  end
end
