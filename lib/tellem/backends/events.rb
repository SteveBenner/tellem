# frozen_string_literal: true

require_relative "../version"
require_relative "../ports/harness_paths"

module Tellem
  module Backends
    module Events
      module_function

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
