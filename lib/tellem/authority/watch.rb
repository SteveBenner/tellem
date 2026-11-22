# frozen_string_literal: true

require_relative "liveness"
require_relative "orphans"
require_relative "rehearse"
require_relative "restore"
require_relative "state"
require_relative "switch"

module Tellem
  module Authority
    module Watch
      module_function

      def before(totals)
        reason = Switch.reason
        outcomes = reason ? Restore.stop(reason) : Restore.retry_failed
        outcomes.select { |outcome| Restore.failed?(outcome) }.each do |outcome|
          totals.errors << { "phase" => "authority", "error_class" => outcome["error"], "message" => outcome["message"].to_s[0, 200] }
        end
      rescue StandardError => e
        totals.errors << { "phase" => "authority", "error_class" => e.class.name, "message" => e.message[0, 200] }
      end

      def after(context, sessions, totals)
        Liveness.run(context, sessions, totals) unless Switch.off?
        Rehearse.run(context, sessions, totals)
        Orphans.run(context.root, sessions, totals)
      rescue StandardError => e
        totals.errors << { "phase" => "authority", "error_class" => e.class.name, "message" => e.message[0, 200] }
      end
    end
  end
end
