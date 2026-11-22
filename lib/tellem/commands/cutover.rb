# frozen_string_literal: true

require "json"
require_relative "../cli"
require_relative "../errors"
require_relative "../reports/options"
require_relative "../cutover/plan"
require_relative "../cutover/apply"

module Tellem
  module Commands
    module Cutover
      USAGE = "tellem cutover plan [--otel] [--claude observe|spool|rehearse|own] [--codex observe|spool] [--specstory coexist|subsume] [--purge] " \
              "[--accept-reader ID]... [--accept-parity NAME]... [--link-target PATH]... | apply --confirm PLAN_ID | rollback --confirm PLAN_ID | " \
              "import --confirm PLAN_ID | status [--json]"
      SINGLE = { "--claude" => "claude", "--codex" => "codex", "--specstory" => "specstory" }.freeze
      REPEATED = { "--accept-reader" => "accept_readers", "--accept-parity" => "accept_parity", "--link-target" => "link_targets" }.freeze

      module_function

      def run(context)
        args = context.args.dup
        verb = args.shift
        case verb
        when "plan" then plan(args)
        when "apply" then confirmed(context, args, :apply)
        when "rollback" then confirmed(context, args, :rollback)
        when "import" then import(args)
        when "status" then status(args)
        else raise UsageError.new(USAGE)
        end
      end

      def import(args)
        options, = Reports::Options.parse(args, usage: USAGE, values: %w[--confirm])
        raise UsageError.new("cutover import needs --confirm PLAN_ID: #{USAGE}") unless options[:confirm]

        job = Tellem::Cutover::History.run(options[:confirm])
        if job["state"] == Tellem::Cutover::History::FAILED
          raise OperationalFailure.new("the history import failed: #{Tellem::Cutover::History.text(job)}", next_command: Tellem::Cutover::History.resume_command(options[:confirm]),
                                                                                                          detail: job)
        end

        { data: job, text: Tellem::Cutover::History.text(job) }
      end

      def status(args)
        Reports::Options.parse(args, usage: USAGE, values: [])
        applied = Tellem::Cutover.latest_applied
        job = Tellem::Cutover::History.current
        lines = [applied ? "cutover plan #{applied['plan_id']} applied at #{applied['at']}" : "no cutover plan is applied"]
        lines << Tellem::Cutover::History.text(job) if job
        { data: { "applied" => applied&.slice("plan_id", "at"), "import" => job }, text: lines.join("\n") }
      end

      def plan(args)
        otel, request = plan_options(args)
        proposal = Tellem::Cutover.plan(otel: otel, request: request)
        public = Tellem::Cutover.public(proposal)
        { data: public.merge("dir" => Tellem::Cutover.dir(public["plan_id"])),
          text: "#{Tellem::Cutover.text(proposal)}\nnext: tellem cutover apply --confirm #{proposal['plan_id']}" }
      end

      def plan_options(args)
        list = args.dup
        otel = false
        request = {}
        until list.empty?
          item = list.shift
          case item
          when "--otel" then otel = true
          when "--purge" then request["purge"] = true
          when *SINGLE.keys then request[SINGLE.fetch(item)] = value_of(item, list)
          when *REPEATED.keys then (request[REPEATED.fetch(item)] ||= []) << value_of(item, list)
          else raise UsageError.new("unknown argument #{item}: #{USAGE}")
          end
        end
        [otel, request]
      end

      def value_of(flag, list)
        value = list.shift
        raise UsageError.new("#{flag} needs a value: #{USAGE}") if value.nil? || value.start_with?("--")

        value
      end

      def confirmed(context, args, action)
        options, = Reports::Options.parse(args, usage: USAGE, values: %w[--confirm])
        return required(context, action) unless options[:confirm]

        result = Tellem::Cutover.public_send(action, options[:confirm])
        { data: result, text: Tellem::Cutover.result_text(result) }
      end

      def required(context, action)
        plan, message = pending(action)
        error = ConfirmationRequired.new(message, next_command: plan && "tellem cutover #{action} --confirm #{plan['plan_id']}")
        if context.json
          context.stdout.puts(JSON.generate(CLI.envelope(context.command, plan, error.to_h)))
        else
          context.stdout.puts(Tellem::Cutover.text(plan)) if plan
          context.stderr.puts("tellem: #{error.message}")
          context.stderr.puts("next: #{error.next_command}") if error.next_command
        end
        error.exit_code
      end

      def pending(action)
        if action == :apply
          plan = Tellem::Cutover.latest
          return [nil, "cutover apply needs --confirm PLAN_ID and there is no plan; run tellem cutover plan"] unless plan

          [plan, "cutover apply would change what plan #{plan['plan_id']} lists; nothing was changed"]
        else
          state = Tellem::Cutover.latest_applied
          return [nil, "cutover rollback needs --confirm PLAN_ID and no plan is applied"] unless state

          plan = Tellem::Cutover.load(state["plan_id"])
          [plan, "cutover rollback would restore what plan #{plan['plan_id']} changed; nothing was changed"]
        end
      end
    end
  end
end
