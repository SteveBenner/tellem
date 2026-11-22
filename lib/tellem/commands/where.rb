# frozen_string_literal: true

require_relative "../reports/command"
require_relative "../reports/where"

module Tellem
  module Commands
    module Where
      USAGE = "tellem where AGENT [--descendants] [--scope PATH | --all] [--strict] [--no-derive] [--json]; " \
              "AGENT is SESSION_KEY, SESSION_KEY/AGENT_KEY, or a subagent id"

      module_function

      def run(context)
        options, rest, scopes, derive = Reports::Command.prepare(context, usage: USAGE, flags: %w[--descendants], positional: 1..1)
        report = Reports::Where.run(scopes, rest.first, descendants: options[:descendants] == true)
        data = Reports::Command.envelope(scopes, derive, report)
        Reports::Command.result(data, Reports::Where.text(report), derive)
      end
    end
  end
end
