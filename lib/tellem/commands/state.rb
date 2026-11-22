# frozen_string_literal: true

require_relative "../reports/command"
require_relative "../reports/state"

module Tellem
  module Commands
    module State
      USAGE = "tellem state AGENT [--since T] [--scope PATH | --all] [--strict] [--no-derive] [--json]; " \
              "AGENT is SESSION_KEY, SESSION_KEY/AGENT_KEY, or a subagent id"

      module_function

      def run(context)
        options, rest, scopes, derive = Reports::Command.prepare(context, usage: USAGE, values: %w[--since], positional: 1..1)
        since = Reports::Options.time_bound(options[:since], "--since")
        report = Reports::State.run(scopes, rest.first, since: since)
        data = Reports::Command.envelope(scopes, derive, report.merge("since" => since))
        Reports::Command.result(data, Reports::State.text(report), derive)
      end
    end
  end
end
