# frozen_string_literal: true

require_relative "../reports/command"
require_relative "../reports/health"

module Tellem
  module Commands
    module Health
      USAGE = "tellem health [--scope PATH | --all] [--strict] [--no-derive] [--json]"

      module_function

      def run(context)
        _options, _rest, scopes, derive = Reports::Command.prepare(context, usage: USAGE)
        report = Reports::Health.run(scopes)
        data = Reports::Command.envelope(scopes, derive, report)
        Reports::Command.result(data, Reports::Health.text(report), derive)
      end
    end
  end
end
