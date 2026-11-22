# frozen_string_literal: true

require_relative "../reports/command"
require_relative "../reports/tree"

module Tellem
  module Commands
    module Tree
      USAGE = "tellem tree [SESSION_KEY] [--scope PATH | --all] [--strict] [--no-derive] [--json]"

      module_function

      def run(context)
        _options, rest, scopes, derive = Reports::Command.prepare(context, usage: USAGE, positional: 0..1)
        sessions = Reports::Tree.run(scopes, session: rest.first)
        data = Reports::Command.envelope(scopes, derive, "sessions" => sessions)
        Reports::Command.result(data, Reports::Tree.text(sessions), derive)
      end
    end
  end
end
