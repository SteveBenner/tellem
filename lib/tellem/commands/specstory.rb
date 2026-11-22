# frozen_string_literal: true

require "json"
require_relative "../cli"
require_relative "../errors"
require_relative "../specstory/prevent"
require_relative "../specstory/remove"

module Tellem
  module Commands
    module Specstory
      USAGE = "tellem specstory remove [--history keep|remove] [--prevent on|off] [--link-target PATH]... [--confirm PLAN_ID] | status [--json]"
      HISTORY = %w[keep remove].freeze
      PREVENT = %w[on off].freeze

      module_function

      def run(context)
        args = context.args.dup
        verb = args.shift
        case verb
        when "remove" then remove(context, args)
        when "status" then status(args)
        else raise UsageError.new(USAGE)
        end
      end

      def parse(args)
        options = { history: "keep", prevent: "on", link_targets: [], confirm: nil }
        list = args.dup
        until list.empty?
          flag = list.shift
          value = list.shift
          raise UsageError.new("#{flag} needs a value: #{USAGE}") if value.nil? || value.start_with?("--")

          case flag
          when "--history" then options[:history] = choice(flag, value, HISTORY)
          when "--prevent" then options[:prevent] = choice(flag, value, PREVENT)
          when "--link-target" then options[:link_targets] << absolute(value)
          when "--confirm" then options[:confirm] = value
          else raise UsageError.new("unknown argument #{flag}: #{USAGE}")
          end
        end
        options
      end

      def choice(flag, value, allowed)
        raise UsageError.new("#{flag} must be one of #{allowed.join(', ')}, not #{value}: #{USAGE}") unless allowed.include?(value)

        value
      end

      def absolute(path)
        raise UsageError.new("--link-target needs an absolute path, not #{path}: #{USAGE}") unless path.start_with?("/")

        path
      end

      def remove(context, args)
        options = parse(args)
        history = options[:history]
        prevent = options[:prevent] == "on"
        command = "tellem specstory remove --history #{history} --prevent #{options[:prevent]}#{options[:link_targets].map { |path| " --link-target #{path}" }.join}"
        if options[:confirm]
          result = Tellem::Specstory::Remove.apply(history: history, prevent: prevent, link_targets: options[:link_targets], confirm: options[:confirm], command: command)
          return { data: result, text: applied_text(result) }
        end

        plan = Tellem::Specstory::Remove.plan(history: history, prevent: prevent, link_targets: options[:link_targets])
        required(context, plan, command)
      end

      def applied_text(result)
        if result["resumed_only"]
          return "resumed the unfinished removal #{result['plan_id']}: #{result['removed']} items removed, #{result['kept_after'].size} kept; receipts in #{Tellem::Specstory::State.log_file}"
        end

        lines = [Tellem::Specstory::Plan.text(result)]
        lines << "applied: #{result['removed']} items removed, #{result['kept_after'].size} kept; receipts in #{Tellem::Specstory::State.log_file}"
        result["kept_after"].each { |item| lines << "  kept #{item['path']}: #{item['cause']}" }
        result["resumed"].each { |item| lines << "  resumed an unfinished removal #{item['plan_id']}: #{item['removed']} removed" }
        lines.join("\n")
      end

      def required(context, plan, command)
        error = ConfirmationRequired.new("specstory remove would delete what the plan lists and cannot be rolled back; nothing was removed; plan #{plan['plan_id']}",
                                         next_command: "#{command} --confirm #{plan['plan_id']}")
        if context.json
          context.stdout.puts(JSON.generate(CLI.envelope(context.command, plan, error.to_h)))
        else
          context.stdout.puts(Tellem::Specstory::Plan.text(plan))
          context.stderr.puts("tellem: #{error.message}")
          context.stderr.puts("next: #{error.next_command}")
        end
        error.exit_code
      end

      def status(args)
        raise UsageError.new(USAGE) unless args.empty?

        info = Tellem::Specstory::Prevent.status
        lines = if info["removed"]
                  ["specstory removal plan #{info['plan_id']} applied at #{info['applied_at']}; prevention #{info['prevent'] ? 'on' : 'off'}; history #{info['history']}",
                   "writer: #{info.dig('writer', 'value')} (#{info.dig('writer', 'reason')})",
                   "stop switch: #{info['stop_switch'] || 'off'}#{info['held'] ? "; drift removal held (#{info['held']})" : ''}"]
                else
                  ["no specstory removal is applied"]
                end
        Tellem::Specstory::Prevent.findings(info).each { |message| lines << "drift: #{message}" }
        { data: info, text: lines.join("\n") }
      end
    end
  end
end
