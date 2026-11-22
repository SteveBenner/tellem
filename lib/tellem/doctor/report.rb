# frozen_string_literal: true

require_relative "../version"
require_relative "../record/scope"
require_relative "../seams"
require_relative "checks"
require_relative "claude_hooks"
require_relative "entry"
require_relative "hook_failure"
require_relative "hook_load"
require_relative "otel"
require_relative "visibility"

module Tellem
  module Doctor
    module Report
      module_function

      def run(cwd: Dir.pwd)
        scope_root = Record::Scope.locate(cwd)
        checks = [
          Entry.guarded("hook_load") { HookLoad.check },
          Entry.guarded("hook_failure") { HookFailure.check },
          Entry.guarded("capture") { Checks.capture(scope_root) },
          Entry.guarded("harness_version") { Checks.harnesses },
          Entry.guarded("registry") { Checks.registry },
          Entry.guarded("backend") { Checks.backend(scope_root) },
          Entry.guarded("persona") { Checks.persona },
          Entry.guarded("rplugin") { Checks.rplugin },
          Entry.guarded("authority") { Checks.authority },
          Entry.guarded("history_import") { Checks.history_import },
          Entry.guarded("claude_hooks") { ClaudeHooks.check },
          Entry.guarded("visibility") { Visibility.check(scope_root) },
          Entry.guarded(Otel::CHECK) { Otel.check }
        ].flatten
        {
          "tellem" => Tellem::VERSION,
          "scope_root" => scope_root,
          "findings" => checks.count { |check| check["status"] == "finding" },
          "checks" => checks,
          "seams" => Seams.status
        }
      end

      def text(report)
        lines = ["tellem doctor: #{report['findings']} finding#{report['findings'] == 1 ? '' : 's'}"]
        report["checks"].each do |check|
          lines << format("  %-8s %-16s %s", check["status"], check["check"], check["message"])
          next unless check["status"] == "finding"

          lines << "  #{' ' * 25} next: #{check['next_command'] || 'none'}"
        end
        unbuilt = report["seams"].select { |_name, state| state == "foundation_default" }.keys
        lines << "  seams on the foundation default: #{unbuilt.join(', ')}" unless unbuilt.empty?
        lines.join("\n")
      end
    end
  end
end
