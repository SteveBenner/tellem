# frozen_string_literal: true

module Tellem
  module Commands
    module Tasks
      USAGE = "tellem tasks [--session S] [--since T] [--scope PATH | --all] [--strict] [--json]; " \
              "tellem tasks parity --against PATH [--json]"

      module_function

      def run(context)
        case context.args.first
        when "parity"
          context.args.shift
          require_relative "../tasks/parity_command"
          Tellem::Tasks::ParityCommand.run(context)
        else
          require_relative "../reports/tasks"
          Tellem::Reports::Tasks.run(context)
        end
      end
    end
  end
end
