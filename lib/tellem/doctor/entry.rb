# frozen_string_literal: true

module Tellem
  module Doctor
    module Entry
      STATUSES = %w[ok finding].freeze

      module_function

      def ok(check, message, detail = nil)
        build(check, "ok", message, nil, detail)
      end

      def finding(check, message, next_command, detail = nil)
        build(check, "finding", message, next_command, detail)
      end

      def build(check, status, message, next_command, detail)
        entry = { "check" => check, "status" => status, "message" => message, "next_command" => next_command }
        detail.nil? ? entry : entry.merge("detail" => detail)
      end

      def guarded(check)
        result = yield
        result.is_a?(Hash) ? [result] : Array(result)
      rescue StandardError, ScriptError => e
        [finding(check, "#{check} check failed: #{e.class}: #{e.message}", "tellem doctor --json")]
      end
    end
  end
end
