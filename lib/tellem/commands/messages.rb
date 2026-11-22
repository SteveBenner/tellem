# frozen_string_literal: true

require_relative "../reports/command"
require_relative "../reports/messages"

module Tellem
  module Commands
    module Messages
      USAGE = "tellem messages [SESSION_KEY] [--agent KEY] [--channel NAME] [--since DURATION] [--scope PATH | --all] [--strict] [--json]"

      module_function

      def run(context)
        options, rest, scopes, derive = Reports::Command.prepare(context, usage: USAGE, values: %w[--agent --channel --since], positional: 0..1)
        since = options[:since] && (Time.now.utc - Reports::Options.duration(options[:since])).strftime(Reports::Options::CANONICAL)
        rows = Reports::Messages.run(scopes, session: rest.first, agent: options[:agent], channel: options[:channel], since: since)
        filters = { "session" => rest.first, "agent" => options[:agent], "channel" => options[:channel], "since" => since }
        data = Reports::Command.envelope(scopes, derive, "filters" => filters, "messages" => rows)
        Reports::Command.result(data, Reports::Messages.text(rows), derive)
      end
    end
  end
end
