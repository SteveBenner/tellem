# frozen_string_literal: true

module Tellem
  module Hook
    module FirstStart
      EVENT = "session_start"
      KILL_SWITCH = "TELLEM_DISABLED"

      module_function

      def applies?(event)
        event == EVENT && ENV[KILL_SWITCH] != "1" && !Record::FS.lexists?(Ports::HarnessPaths.capture_flag) &&
          !Record::FS.lexists?(Ports::HarnessPaths.capture_settled)
      end

      def sync
        require File.join(Ports::HarnessPaths.rplugin_home, "lib", "rplugin")
        require_relative "../config/resolver"
        Config.sync_capture_flag
        settle unless Record::FS.lexists?(Ports::HarnessPaths.capture_flag)
      end

      def settle
        Record::FS.mkdir_p(Ports::HarnessPaths.state_dir)
        Record::FS.write_new(Ports::HarnessPaths.capture_settled, "") unless Record::FS.lexists?(Ports::HarnessPaths.capture_settled)
      end
    end
  end
end
