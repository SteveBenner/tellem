# frozen_string_literal: true

module Tellem
  module Hook
    module Spawn
      DERIVE_EVENTS = %w[stop session_end subagent_stop].freeze

      module_function

      def derive?(harness, event, tool)
        return true if DERIVE_EVENTS.include?(event)

        event == "post_tool" && Ports::HarnessPaths.spawn_tools(harness).include?(tool)
      end

      def deriver(plugin_root, scope_root)
        require "rbconfig"
        pid = Process.spawn(RbConfig.ruby, File.join(plugin_root, "bin", "tellem"), "derive", "--scope", scope_root, "--detached",
                            pgroup: true, in: :close, out: File::NULL, err: File::NULL)
        Process.detach(pid)
        pid
      end
    end
  end
end
