# frozen_string_literal: true

module Tellem
  module Ports
    class TranscriptPolicy < Rplugin::Ports::Base
      def withhold_tools
        []
      end

      def withhold_paths
        []
      end

      def native_readers
        []
      end
    end
  end
end
