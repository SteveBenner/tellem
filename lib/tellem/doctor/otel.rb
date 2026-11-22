# frozen_string_literal: true

require_relative "../otel/settings"
require_relative "../otel/state"
require_relative "../otel/status"
require_relative "entry"

module Tellem
  module Doctor
    module Otel
      CHECK = "otel"
      STATUS = "tellem otel status"
      PORT = "tellem config set otel.port PORT"

      module_function

      def check
        settings = Tellem::Otel::Settings
        state = Tellem::Otel::State.read
        pid = Tellem::Otel::State.running_pid
        receiver = Tellem::Otel::Status.receiver(state, pid)
        address = "#{settings::HOST}:#{settings.port}"
        detail = { "enabled" => settings.enabled?, "kill_switch" => settings.disabled?, "address" => address,
                   "receiver" => receiver, "pid" => pid, "error_class" => state["error_class"] }.compact
        return Entry.ok(CHECK, off_message(settings), detail) unless detail["enabled"]
        return Entry.ok(CHECK, "receiver running on #{address} (pid #{pid})", detail) if pid

        finding(receiver, address, detail)
      end

      def off_message(settings)
        settings.disabled? ? "receiver off (#{settings::KILL_SWITCH}=1)" : "receiver off (otel.receiver false)"
      end

      def finding(receiver, address, detail)
        case receiver
        when "port_in_use"
          Entry.finding(CHECK, "receiver enabled but #{address} is held by another listener (port_in_use)", PORT, detail)
        when "inherit_failed"
          Entry.finding(CHECK, "receiver enabled but could not adopt its listening socket (inherit_failed)", STATUS, detail)
        else
          Entry.finding(CHECK, "receiver enabled but not running on #{address} (#{receiver})", STATUS, detail)
        end
      end
    end
  end
end
