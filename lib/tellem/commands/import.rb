# frozen_string_literal: true

require "json"
require_relative "../cli"
require_relative "../errors"
require_relative "../reports/options"
require_relative "../import/plan"

module Tellem
  module Commands
    module Import
      USAGE = "tellem import native|specstory|ledger [--path P] [--confirm PLAN_ID] [--json]"

      module_function

      def run(context)
        options, rest = Reports::Options.parse(context.args, usage: USAGE, values: %w[--path --confirm], positional: 1..1)
        kind = rest.first
        raise UsageError.new("unknown import source #{kind}: #{USAGE}") unless Tellem::Import::KINDS.include?(kind)

        paths = options[:path] ? [options[:path]] : []
        if options[:confirm]
          result = Tellem::Import.apply(options[:confirm], [kind], paths)
          return { data: result, text: Tellem::Import.applied_text(result) }
        end

        required(context, Tellem::Import.plan([kind], paths))
      end

      def required(context, plan)
        error = ConfirmationRequired.new("import is a dry run until confirmed; plan #{plan['plan_id']}; nothing was imported",
                                         next_command: "#{Tellem::Import.command(plan)} --confirm #{plan['plan_id']}")
        if context.json
          context.stdout.puts(JSON.generate(CLI.envelope(context.command, plan, error.to_h)))
        else
          context.stdout.puts(Tellem::Import.text(plan))
          context.stderr.puts("tellem: #{error.message}")
          context.stderr.puts("next: #{error.next_command}")
        end
        error.exit_code
      end
    end
  end
end
