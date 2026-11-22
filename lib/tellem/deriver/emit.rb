# frozen_string_literal: true

require_relative "../version"
require_relative "../ports/harness_paths"

module Tellem
  module Deriver
    module Emit
      module_function

      def completed(summary, totals)
        totals.gaps.each do |gap|
          emit("tellem.gap.recorded", {
                 "scope_id" => summary["scope_id"], "session_key" => gap["session_key"], "cause" => gap["body"]["cause"],
                 "harness" => gap["body"]["harness"], "harness_version" => gap["body"]["harness_version"]
               })
        end
        emit("tellem.derive.completed", summary.slice("scope_id", "sessions", "observations_added", "gaps_added", "duration_ms", "phase_ms"))
      end

      def emit(kind, payload)
        return nil unless defined?(Rplugin::Ports)

        port.emit(kind, payload)
      rescue StandardError
        nil
      end

      def port
        @port ||= Rplugin::Ports.for(Ports::HarnessPaths::PLUGIN_ID, root: Tellem.root).events
      end
    end
  end
end
