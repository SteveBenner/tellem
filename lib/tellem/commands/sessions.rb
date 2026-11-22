# frozen_string_literal: true

require_relative "../errors"
require_relative "../reports/command"
require_relative "../reports/options"
require_relative "../reports/sessions"
require_relative "../reports/sessions_brief"

module Tellem
  module Commands
    module Sessions
      USAGE = "tellem sessions [--repo PATH | --scope PATH | --all] [--strict] [--no-derive] [--brief [--since T] [--limit N]] [--json]"

      module_function

      def run(context)
        args = context.args.dup
        index = args.index("--repo")
        if index
          path = args[index + 1]
          raise UsageError.new("--repo needs a path: #{USAGE}") if path.nil? || path.start_with?("--")
          raise UsageError.new("--repo excludes --scope and --all: #{USAGE}") if args.include?("--scope") || args.include?("--all")

          args[index] = "--scope"
        end
        context = context.dup
        context.args = args
        options, _rest, scopes, derive = Reports::Command.prepare(context, usage: USAGE, values: %w[--since --limit], flags: %w[--brief])
        return brief(options, scopes, derive) if options[:brief]
        raise UsageError.new("--since and --limit need --brief: #{USAGE}") if options[:since] || options[:limit]

        rows = Reports::Sessions.run(scopes)
        data = Reports::Command.envelope(scopes, derive, "sessions" => rows)
        Reports::Command.result(data, Reports::Sessions.text(rows), derive)
      end

      def brief(options, scopes, derive)
        rows = Reports::SessionsBrief.run(scopes, since: Reports::Options.time_bound(options[:since], "--since"), limit: limit(options[:limit]))
        data = Reports::Command.envelope(scopes, derive, "sessions" => rows)
        Reports::Command.result(data, Reports::SessionsBrief.text(rows), derive)
      end

      def limit(value)
        return nil if value.nil?

        number = Integer(value, 10)
        raise ArgumentError if number < 1

        number
      rescue ArgumentError
        raise UsageError.new("--limit must be a positive integer, not #{value}")
      end
    end
  end
end
