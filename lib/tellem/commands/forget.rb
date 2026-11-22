# frozen_string_literal: true

require "json"
require_relative "../cli"
require_relative "../entries/forget"
require_relative "../errors"
require_relative "../ids"
require_relative "../record/scope"
require_relative "../reports/options"
require_relative "../reports/scopes"

module Tellem
  module Commands
    module Forget
      USAGE = "tellem forget --session KEY | --all [--scope PATH] [--confirm PLAN_ID] [--json]"

      module_function

      def run(context)
        options, = Reports::Options.parse(context.args, usage: USAGE, values: %w[--session --scope --confirm], flags: %w[--all])
        raise UsageError.new("forget needs exactly one of --session or --all: #{USAGE}") if options[:session].nil? == (options[:all] != true)

        root = Reports::Scopes.root_for(File.expand_path(options[:scope] || Dir.pwd))
        scope = Reports::Scopes.entry(root)
        keys, rule = selection(root, options)
        command = "tellem forget #{options[:session] ? "--session #{options[:session]}" : '--all'} --scope #{root}"
        return confirmed(scope, keys, rule, options[:confirm], command) if options[:confirm]

        plan = Entries::Forget.plan(scope, keys, rule)
        required(context, plan, command)
      end

      def selection(root, options)
        if options[:session]
          raise UsageError.new("invalid session key: #{USAGE}") unless Ids.valid_session_key?(options[:session])

          return [[options[:session]], "forget session #{options[:session]}"]
        end

        [Record::Scope.session_keys(root), "forget all"]
      end

      def confirmed(scope, keys, rule, confirm, command)
        result = Entries::Forget.apply(scope, keys, rule, confirm, command)
        { data: result, text: "#{Entries::Forget.text(result)}\napplied; receipts appended to #{Entries::Forget.log_path(scope['root'])}" }
      end

      def required(context, plan, command)
        error = ConfirmationRequired.new("forget would remove what the plan lists; nothing was removed; plan #{plan['plan_id']}",
                                         next_command: "#{command} --confirm #{plan['plan_id']}")
        if context.json
          context.stdout.puts(JSON.generate(CLI.envelope(context.command, plan, error.to_h)))
        else
          context.stdout.puts(Entries::Forget.text(plan))
          context.stderr.puts("tellem: #{error.message}")
          context.stderr.puts("next: #{error.next_command}")
        end
        error.exit_code
      end
    end
  end
end
