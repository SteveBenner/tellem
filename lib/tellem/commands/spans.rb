# frozen_string_literal: true

require_relative "../reports/command"
require_relative "../reports/spans"

module Tellem
  module Commands
    module Spans
      USAGE = Reports::Spans::USAGE

      module_function

      def run(context)
        options, _rest, scopes, derive = Reports::Command.prepare(context, usage: USAGE, values: %w[--session --task --agent --kind --since --until --limit],
                                                                           flags: %w[--descendants])
        params = Reports::Spans.params(options)
        raise UsageError.new("--descendants needs --agent: #{USAGE}") if params["descendants"] && params["agent"].nil?

        rows, total = Reports::Spans.run(scopes, params)
        filters = params.reject { |key, value| key == "limit" || value.nil? || value == false }
        data = Reports::Command.envelope(scopes, derive, "filters" => filters, "truncated" => rows.size < total, "total" => total, "rows" => rows)
        Reports::Command.result(data, Reports::Spans.text(rows, total), derive, ["source: files"])
      end
    end
  end
end
