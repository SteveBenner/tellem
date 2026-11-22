# frozen_string_literal: true

require "rbconfig"
require_relative "../version"
require_relative "entry"

module Tellem
  module Doctor
    module HookLoad
      CHECK = "hook_load"
      BUDGET_MS = 50
      WARM_SAMPLES = 5
      TIMEOUT_S = 5

      module_function

      def check
        entry = File.join(Tellem.root, "lib", "tellem", "hook", "main.rb")
        argv = [RbConfig.ruby, "--disable-gems", "-e", "require ARGV.fetch(0)", entry]
        cold = sample(argv)
        warm = Array.new(WARM_SAMPLES) { sample(argv) }
        detail = { "entrypoint" => entry, "cold_ms" => cold, "warm_ms" => warm, "budget_ms" => BUDGET_MS }
        return [Entry.finding(CHECK, "the hook entrypoint did not load within #{TIMEOUT_S} s or exited non-zero", "ruby --disable-gems #{entry}", detail)] if warm.any?(&:nil?) || cold.nil?

        median = warm.sort[warm.size / 2]
        detail = detail.merge("warm_median_ms" => median, "warm_max_ms" => warm.max)
        if median > BUDGET_MS
          [Entry.finding(CHECK, "hook entrypoint warm load #{median} ms exceeds the #{BUDGET_MS} ms budget", "tellem health --all", detail)]
        else
          [Entry.ok(CHECK, "hook entrypoint loads in #{median} ms warm, #{cold} ms cold (budget #{BUDGET_MS} ms)", detail)]
        end
      end

      def sample(argv)
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        pid = Process.spawn(*argv, in: File::NULL, out: File::NULL, err: File::NULL, pgroup: true)
        waiter = Process.detach(pid)
        unless waiter.join(TIMEOUT_S)
          kill(pid)
          waiter.join(1)
          return nil
        end
        elapsed = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round(1)
        waiter.value.success? ? elapsed : nil
      rescue SystemCallError
        nil
      end

      def kill(pid)
        Process.kill("KILL", -pid)
      rescue SystemCallError
        nil
      end
    end
  end
end
