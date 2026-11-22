# frozen_string_literal: true

require_relative "../errors"
require_relative "../authority/restore"
require_relative "../authority/state"
require_relative "../authority/switch"
require_relative "../cli"

module Tellem
  module Commands
    module Authority
      USAGE = "tellem authority stop | resume | restore | status [--json]"

      module_function

      def run(context)
        args = context.args.dup
        verb = args.shift
        raise UsageError.new(USAGE) unless args.empty?

        case verb
        when "stop" then stop
        when "resume" then resume
        when "restore" then restore
        when "status" then status
        else raise UsageError.new(USAGE)
        end
      end

      def stop
        Tellem::Authority::Switch.set("set by tellem authority stop")
        lowered = Tellem::Authority::Restore.stop("tellem_authority_stop")
        refuse_failed(lowered, "the flag is set and the next derive restores")
        { data: { "off" => true, "flag" => Tellem::Authority::Switch.flag_path, "lowered" => lowered },
          text: stop_text(lowered) }
      end

      def restore
        before = Tellem::Authority::State.restore_failures
        return { data: { "pending" => false, "restored" => [] }, text: "no authority restore is pending" } if before.empty?

        outcomes = Tellem::Authority::Restore.retry_failed
        refuse_failed(outcomes, "every derive keeps retrying")
        { data: { "pending" => false, "restored" => outcomes },
          text: outcomes.empty? ? "the pending restore no longer applies; the level is already observe" : stop_text(outcomes).lines.reject { |line| line.start_with?("authority stopped") }.join.chomp }
      end

      def refuse_failed(outcomes, promise)
        failed = outcomes.select { |item| Tellem::Authority::Restore.failed?(item) }
        return if failed.empty?

        message = failed.map { |item| "#{item['harness']}: #{item['file']}: #{item['error']}; #{Tellem::Authority::Restore.fix(item)}" }.join("; ")
        detail = { "restore_failed" => failed }
        raise Busy.new("restore could not run: #{message}; #{promise}", next_command: Tellem::Authority::Restore::COMMAND, detail: detail) if failed.all? { |item| item["error"] == Tellem::Authority::Restore::BUSY }

        raise OperationalFailure.new("restore failed: #{message}; #{promise}", next_command: Tellem::Authority::Restore::COMMAND, detail: detail)
      end

      def stop_text(lowered)
        lines = ["authority stopped: retention, purge, body removal, and SpecStory drift removal are halted; flag #{Tellem::Authority::Switch.flag_path}"]
        lowered.each do |item|
          lines << "  #{item['harness']}: #{item['from']} -> #{item['to']}; removed env #{item['env_removed'].empty? ? 'none' : item['env_removed'].join(', ')}"
        end
        lines << "  sessions already running keep the environment they started with"
        lines.join("\n")
      end

      def resume
        cleared = Tellem::Authority::Switch.clear
        { data: { "cleared" => cleared, "off" => Tellem::Authority::Switch.off? },
          text: "authority flag #{cleared ? 'cleared' : 'was not set'}; no level was raised, only a new plan raises one" }
      end

      def status
        state = Tellem::Authority::State
        levels = state::HARNESSES.to_h { |name| [name, state.level(name)] }
        data = { "levels" => levels, "off" => Tellem::Authority::Switch.reason, "losses" => state.losses, "generation" => state.generation,
                 "restore_failed" => state.restore_failures }
        lines = levels.map { |name, level| "#{name}: #{level}" }
        lines << "stop switch: #{data['off'] || 'off'}"
        data["restore_failed"].each do |name, item|
          lines << "restore failed: #{name} #{item['kind']} #{item['reason']}; #{item['file']}: #{item['error']}; #{Tellem::Authority::Restore.fix(item)}; retried at every derive, or run #{Tellem::Authority::Restore::COMMAND}"
        end
        data["losses"].each { |item| lines << "lost: #{item['kind']} #{item['reason']} at #{item['at']} (#{item['session_key'] || 'no session'}); plan own anew or roll back" }
        { data: data, text: lines.join("\n") }
      end
    end
  end
end
