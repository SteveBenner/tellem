# frozen_string_literal: true

require_relative "../config/resolver"
require_relative "../errors"
require_relative "../reports/command"
require_relative "../reports/options"
require_relative "../reports/records"
require_relative "../reports/text"
require_relative "parity"
require_relative "totals"

module Tellem
  module Tasks
    module ParityCommand
      USAGE = "tellem tasks parity --against PATH [--scope PATH | --all] [--strict] [--no-derive] [--json]; " \
              "PATH is the task clock's tasks state directory (t/*.json and s/*.json), opened read-only"
      MODES = %w[on].freeze
      MODE_NEXT = "tellem config set tasks.mode on"
      CAUSE_HEADERS = %w[cause tasks].freeze
      SESSION_HEADERS = %w[session stored derived matched differing only_stored only_derived stored_turns derived_turns clock_prompts causes].freeze
      TASK_HEADERS = %w[status stored derived started name causes].freeze

      module_function

      def run(context)
        against = against(context.args)
        stored = Parity.store(against)
        options, _rest, scopes, derive = Reports::Command.prepare(context, usage: USAGE, values: %w[--against])
        live = Reports::Scopes.live(scopes)
        active = live.select { |scope| MODES.include?(Config.get("tasks.mode", scope: scope["root"])) }
        if active.empty?
          raise OperationalFailure.new("tasks.mode is off for every scope in this comparison, so no task is derived",
                                       next_command: MODE_NEXT)
        end

        derived = active.flat_map { |scope| Reports::Records.load(scope).of_kind("task").map { |record| record["body"] } }
        derived = derived.select { |task| Parity.usable?(task) }
        report = Parity.compare(stored, derived, Config.tasks_rules, Time.now.to_f)
        body = { "against" => stored[:root], "skipped_scopes" => (live - active).map { |scope| scope["root"] } }.merge(report)
        data = Reports::Command.envelope(scopes, derive, body)
        Reports::Command.result(data, text(body), derive, ["against: #{stored[:root]}", "scope: #{options[:scope] || (options[:all] ? 'all' : 'current')}"])
      end

      def against(args)
        options, = Reports::Options.parse(args.dup, usage: USAGE, values: Reports::Command::SCOPE_VALUES + %w[--against],
                                                    flags: Reports::Command::SCOPE_FLAGS)
        raise UsageError.new("--against PATH is required: #{USAGE}") unless options[:against]

        options[:against]
      end

      def text(body)
        [
          summary(body),
          "by cause (matched tasks)\n#{Reports::Text.table(CAUSE_HEADERS, body['by_cause'].map { |cause, count| [cause, count.to_s] })}",
          "sessions\n#{Reports::Text.table(SESSION_HEADERS, body['sessions'].map { |row| session_line(row) })}",
          "tasks that differ or exist on one side only\n#{Reports::Text.table(TASK_HEADERS, task_lines(body['tasks']))}",
          totals(body["totals"])
        ].join("\n\n")
      end

      def summary(body)
        lines = [
          "stored #{body['stored']['tasks']} tasks in #{body['stored']['sessions']} sessions, derived #{body['derived']['tasks']} tasks, at #{body['now']}",
          "matched #{body['matched']} (identical #{body['identical']}, differing #{body['differing']}), " \
          "only stored #{body['only_stored']}, only derived #{body['only_derived']}",
          "tolerance #{body['tolerance_s']} s for times, match window #{body['match_window_s']} s on the start"
        ]
        unreadable = body["stored"]["unreadable"]
        lines << "unreadable in the store: #{unreadable.map { |item| "#{item['file']} (#{item['reason']})" }.join(', ')}" unless unreadable.empty?
        lines.join("\n")
      end

      def session_line(row)
        [row["session_id"], *%w[stored_tasks derived_tasks matched differing only_stored only_derived stored_turns derived_turns clock_prompts].map { |key| Reports::Text.cell(row[key]) },
         Reports::Text.cell(row["causes"].map { |cause, count| "#{cause}:#{count}" })]
      end

      def task_lines(rows)
        rows.reject { |row| row["status"] == "identical" }.map do |row|
          [row["status"], Reports::Text.cell(row["stored_id"]), Reports::Text.cell(row["derived_id"]),
           Time.at(row["started"]).utc.strftime("%Y-%m-%dT%H:%M:%SZ"), Reports::Text.cell(row["name"].to_s[0, 40]), Reports::Text.cell(row["causes"])]
        end
      end

      def totals(values)
        rows = %w[tasks turns subagents elapsed active agents].map do |key|
          [key, Reports::Text.cell(values["stored"][key]), Reports::Text.cell(values["derived"][key])]
        end
        "totals at the same time\n#{Reports::Text.table(%w[field stored derived], rows)}"
      end
    end
  end
end
