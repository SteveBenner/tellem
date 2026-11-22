# frozen_string_literal: true

module Tellem
  module Deriver
    class Timer
      def initialize(phases)
        @started = now
        @phase_ms = phases.to_h { |name| [name, 0] }
      end

      def phase(name)
        started = now
        yield
      ensure
        @phase_ms[name] = @phase_ms.fetch(name, 0) + (now - started)
      end

      def phase_ms
        @phase_ms.dup
      end

      def elapsed_ms
        now - @started
      end

      def now
        Process.clock_gettime(Process::CLOCK_MONOTONIC, :millisecond)
      end
    end
  end
end
