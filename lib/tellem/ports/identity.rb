# frozen_string_literal: true

module Tellem
  module Ports
    class Identity < Rplugin::Ports::Base
      AUTHORITIES = %w[transcript_observed sampled unknown].freeze

      def snapshot(harness:, session_id:)
        :unknown
      end

      def from_tool_result(text:, at:)
        nil
      end

      def transition_command?(command)
        false
      end
    end
  end
end
