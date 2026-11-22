# frozen_string_literal: true

require_relative "../entries/search"
require_relative "../errors"
require_relative "../reports/options"
require_relative "../reports/scopes"

module Tellem
  module Commands
    module Search
      USAGE = "tellem search QUERY [--scope PATH | --all] [--limit N] [--json]"
      DEFAULT_LIMIT = 20
      MAX_LIMIT = 1000

      module_function

      def run(context)
        options, rest = Reports::Options.parse(context.args, usage: USAGE, values: %w[--scope --limit], flags: %w[--all], positional: 1..1)
        query = rest.first
        raise UsageError.new("QUERY must be 1 to #{Entries::Search::QUERY_BYTES} bytes: #{USAGE}") if query.empty? || query.bytesize > Entries::Search::QUERY_BYTES

        scopes = Reports::Scopes.live(Reports::Scopes.resolve(scope: options[:scope] && File.expand_path(options[:scope]), all: options[:all] == true))
        result = Entries::Search.run(scopes, query, limit: limit(options[:limit]))
        { data: result, text: text(result) }
      end

      def limit(value)
        return DEFAULT_LIMIT if value.nil?

        number = Integer(value, 10)
        raise ArgumentError unless number.positive? && number <= MAX_LIMIT

        number
      rescue ArgumentError
        raise UsageError.new("--limit must be an integer from 1 to #{MAX_LIMIT}: #{USAGE}")
      end

      def text(result)
        lines = result["matches"].map do |match|
          "#{match['session_key']}/#{match['agent_key']}:#{match['line']}: #{match['excerpt']}"
        end
        lines << "(more matches than --limit)" if result["truncated"]
        lines << "no matches" if result["matches"].empty?
        lines.join("\n")
      end
    end
  end
end
