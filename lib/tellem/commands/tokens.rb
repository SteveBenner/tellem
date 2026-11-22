# frozen_string_literal: true

require_relative "../reports/command"
require_relative "../reports/tasks"
require_relative "../reports/tokens"

module Tellem
  module Commands
    module Tokens
      USAGE = "tellem tokens [--by DIM[,DIM]] [--session S] [--since T] [--until T] [--scope PATH | --all] [--strict] [--no-derive] [--tasks] [--json]; " \
              "DIM is agent, session, subagent_type, model, effort, repository, place, persona, or day"

      module_function

      def run(context)
        options, _rest, scopes, derive = Reports::Command.prepare(context, usage: USAGE, values: %w[--by --session --since --until], flags: %w[--tasks])
        return tasks(options, scopes, derive) if options[:tasks]

        params = Reports::Tokens.params(by: options[:by], session: options[:session], since: options[:since], until_time: options[:until])
        rows, source = Reports::Tokens.run(scopes, params)
        query = params.reject { |key, value| key == "by" || value.nil? }
        data = Reports::Command.envelope(scopes, derive, "by" => params["by"], "filters" => query, "rows" => rows)
        Reports::Command.result(data, Reports::Tokens.text(rows, params["by"]), derive, ["source: #{source == 'files' ? 'files' : "#{source} mirror"}"])
      end

      def tasks(options, scopes, derive)
        rows, dims, params = Reports::Tasks.tokens_report(scopes, by: options[:by], session: options[:session], since: options[:since], until_time: options[:until])
        query = params.reject { |key, value| key == "by" || value.nil? }
        data = Reports::Command.envelope(scopes, derive, "by" => dims, "tasks" => true, "filters" => query, "rows" => rows)
        Reports::Command.result(data, Reports::Tasks.text(rows, dims), derive, ["source: files"])
      end
    end
  end
end
