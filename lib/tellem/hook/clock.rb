# frozen_string_literal: true

module Tellem
  module Hook
    module Clock
      STAT = "/proc/self/stat"
      UPTIME = "/proc/uptime"
      USER_HZ = 100.0
      STARTTIME_INDEX = 19

      module_function

      def hook_ms
        stat = File.read(STAT)
        ticks = Integer(stat[(stat.rindex(")") + 2)..].split(" ")[STARTTIME_INDEX], 10)
        uptime = Float(File.read(UPTIME).split(" ").first)
        elapsed = ((uptime - (ticks / USER_HZ)) * 1000).round
        elapsed.negative? ? 0 : elapsed
      rescue SystemCallError, ArgumentError, TypeError, NoMethodError
        nil
      end
    end
  end
end
