# frozen_string_literal: true

require "json"
require_relative "../cli"
require_relative "../errors"
require_relative "../reports/options"
require_relative "../reports/prune"
require_relative "../reports/scopes"

module Tellem
  module Commands
    module Prune
      USAGE = "tellem prune --older-than DURATION | --max-bytes SIZE [--scope PATH] [--confirm PLAN_ID] [--json]"

      module_function

      def run(context)
        options, = Reports::Options.parse(context.args, usage: USAGE, values: %w[--older-than --max-bytes --scope --confirm])
        rule = rule(options)
        root = Reports::Scopes.root_for(File.expand_path(options[:scope] || Dir.pwd))
        scope = Reports::Scopes.entry(root)
        return confirmed(scope, rule, options[:confirm]) if options[:confirm]

        plan = Reports::Prune.plan(scope, rule)
        required(context, plan, "prune would remove what the plan lists; nothing was removed")
      end

      def rule(options)
        older = options[:older_than]
        size = options[:max_bytes]
        raise UsageError.new("prune needs exactly one of --older-than or --max-bytes: #{USAGE}") if older.nil? == size.nil?

        if older
          Reports::Prune::Rule.new(name: "older-than", argument: older, value: Reports::Options.duration(older))
        else
          Reports::Prune::Rule.new(name: "max-bytes", argument: size, value: Reports::Options.size(size))
        end
      end

      def confirmed(scope, rule, confirm)
        result = Reports::Prune.apply(scope, rule, confirm)
        { data: result, text: "#{Reports::Prune.text(result)}\napplied; receipt appended to #{Record::Scope.prune_log(scope['root'])}" }
      end

      def required(context, plan, message)
        error = ConfirmationRequired.new("#{message}; plan #{plan['plan_id']}",
                                         next_command: "tellem prune --#{plan['rule']} --scope #{plan['root']} --confirm #{plan['plan_id']}")
        if context.json
          context.stdout.puts(JSON.generate(CLI.envelope(context.command, plan, error.to_h)))
        else
          context.stdout.puts(Reports::Prune.text(plan))
          context.stderr.puts("tellem: #{error.message}")
          context.stderr.puts("next: #{error.next_command}")
        end
        error.exit_code
      end
    end
  end
end
