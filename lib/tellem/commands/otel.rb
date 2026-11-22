# frozen_string_literal: true

require_relative "../reports/command"
require_relative "../otel/status"

module Tellem
  module Commands
    module Otel
      USAGE = "tellem otel status [--scope PATH | --all] [--strict] [--no-derive] [--json]"

      module_function

      def run(context)
        sub = context.args.first
        raise UsageError.new("otel needs status: #{USAGE}") unless sub == "status"

        context.args = context.args.drop(1)
        _options, _rest, scopes, derive = Reports::Command.prepare(context, usage: USAGE)
        report = Tellem::Otel::Status.report(scopes)
        data = Reports::Command.envelope(scopes, derive, report)
        Reports::Command.result(data, Tellem::Otel::Status.text(report), derive)
      end
    end
  end
end
