# frozen_string_literal: true

require_relative "../reports/command"
require_relative "../reports/options"
require_relative "../parity/report"
require_relative "../parity/bodies"
require_relative "../authority/ledger"

module Tellem
  module Commands
    module Parity
      USAGE = "tellem parity [bodies] [--session S] [--since T] [--scope PATH | --all] [--strict] [--no-derive] [--json]"
      BODIES = "bodies"

      module_function

      def run(context)
        options, rest, scopes, derive = Reports::Command.prepare(context, usage: USAGE, values: %w[--session --since], positional: 0..1)
        return bodies(options, scopes, derive) if rest.first == BODIES
        raise UsageError, USAGE unless rest.empty?

        since = Reports::Options.time_bound(options[:since], "--since")
        report = Tellem::Parity.run(scopes, session: options[:session], since: since)
        data = Reports::Command.envelope(scopes, derive, report)
        Reports::Command.result(data, Tellem::Parity.text(report), derive)
      end

      def bodies(options, scopes, derive)
        report = Tellem::Parity::Bodies.run(scopes, session: options[:session])
        report["recorded"] = Tellem::Authority::Ledger.rows.select { |row| options[:session].nil? || row["session_key"].end_with?(options[:session]) }
        Reports::Command.result(Reports::Command.envelope(scopes, derive, report), Tellem::Parity::Bodies.text(report), derive)
      end
    end
  end
end
