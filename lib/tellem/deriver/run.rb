# frozen_string_literal: true

require_relative "../config/resolver"
require_relative "../errors"
require_relative "../ports/harness_paths"
require_relative "../record/fs"
require_relative "../record/lock"
require_relative "../record/scope"
require_relative "timer"
require_relative "pass"
require_relative "emit"
require_relative "tasks"

module Tellem
  module Deriver
    PHASES = %w[
      config raw places workspace transcripts alignment remote persona lifecycle tasks pointers registry projections mirror events
    ].freeze
    EXTRA_PASSES = 3
    WAIT_S = 10

    module_function

    def available?
      true
    end

    def foundation_default?
      false
    end

    def run(scope_root, wait: false, wait_s: WAIT_S)
      timer = Timer.new(PHASES)
      root = resolve_root(scope_root)
      return summary(root, "disabled", timer) unless enabled?(root)

      handle = Record::Lock.acquire(root)
      return held(root, wait, wait_s, timer) unless handle

      begin
        locked(root, timer)
      ensure
        Record::Lock.release(handle)
      end
    end

    def locked(root, timer)
      totals = Totals.new
      passes = 0
      loop do
        Record::Lock.clear_dirty(root)
        Pass.new(root, timer, totals).run
        passes += 1
        break unless passes <= EXTRA_PASSES && Record::Lock.dirty?(root)
      end
      timer.phase("tasks") { derive_tasks(root, totals) }
      result = summary(root, "ran", timer, totals: totals, passes: passes)
      timer.phase("events") { Emit.completed(result, totals) }
      result.merge("duration_ms" => timer.elapsed_ms, "phase_ms" => timer.phase_ms)
    end

    def derive_tasks(root, totals)
      Tasks.derive(root, totals)
    rescue StandardError => e
      totals.errors << { "phase" => "tasks", "error_class" => e.class.name, "message" => e.message[0, 200] }
    end

    def held(root, wait, wait_s, timer)
      return summary(root, "dirty", timer) unless wait

      idle = Record::Lock.wait_idle(root, timeout_s: wait_s)
      summary(root, idle ? "waited" : "busy", timer)
    end

    def enabled?(root)
      Config.get("features.derive", scope: root) == true
    end

    def resolve_root(scope_root)
      path = File.expand_path(scope_root.to_s.empty? ? Dir.pwd : scope_root.to_s)
      user = Record::Scope.user_root
      return user if path == user

      raise OperationalFailure.new("scope path does not exist: #{path}", next_command: "tellem sync --scope PATH") unless File.exist?(path)

      Record::Scope.locate(path)
    end

    def summary(root, status, timer, totals: nil, passes: 0)
      {
        "scope_root" => root,
        "scope_id" => Record::Scope.scope_id(root),
        "status" => status,
        "passes" => passes,
        "sessions" => totals ? totals.sessions.size : 0,
        "observations_added" => totals ? totals.observations : 0,
        "gaps_added" => totals ? totals.gaps.size : 0,
        "duration_ms" => timer.elapsed_ms,
        "phase_ms" => timer.phase_ms
      }
    end

    class Totals
      attr_reader :sessions, :gaps, :errors
      attr_accessor :observations, :mirror

      def initialize
        @sessions = {}
        @gaps = []
        @errors = []
        @observations = 0
        @mirror = nil
      end

      def session(key)
        @sessions[key] = true
      end

      def absorb(result)
        @observations += result.fetch("appended", 0)
        @gaps.concat(result.fetch("gaps", []))
      end
    end
  end
end
