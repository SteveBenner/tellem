# frozen_string_literal: true

require_relative "../errors"
require_relative "../doctor/report"

module Tellem
  module Commands
    module Doctor
      USAGE = "tellem doctor [--json]"

      module_function

      def run(context)
        raise UsageError.new("doctor takes no arguments: #{USAGE}") unless context.args.empty?

        report = Tellem::Doctor::Report.run
        { data: report, text: Tellem::Doctor::Report.text(report) }
      end
    end
  end
end
