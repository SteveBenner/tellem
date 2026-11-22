# frozen_string_literal: true

require_relative "../bounds"
require_relative "../redact"
require_relative "args"
require_relative "shell"
require_relative "targets"
require_relative "net"
require_relative "ops"

module Tellem
  module Places
    module Remote
      Context = Struct.new(:cwd, :env, :lookup)

      HANDLERS = {
        "ssh" => Net.method(:ssh),
        "scp" => Net.method(:scp),
        "rsync" => Net.method(:rsync),
        "curl" => Net.method(:curl),
        "wget" => Net.method(:wget),
        "docker" => Ops.method(:docker),
        "kubectl" => Ops.method(:kubectl),
        "git" => Ops.method(:git)
      }.freeze
      WRAPPER_DEPTH = 16
      PROGRAM_BYTES = 200
      SUDO_SHORT = "gpCrtUDRTu"
      SUDO_LONG = %w[group prompt close-from role type other-user chdir chroot command-timeout user host].freeze
      SUDO_NO_COMMAND = %w[-e --edit -l --list -v --validate -k --reset-timestamp -K --remove-timestamp -V --version].freeze
      ENV_SHORT = "uCS"
      ENV_LONG = %w[unset chdir split-string].freeze
      TIMEOUT_SHORT = "sk"
      TIMEOUT_LONG = %w[signal kill-after].freeze
      XARGS_SHORT = "aEILnPsd"
      XARGS_OPTIONAL = "iel"
      XARGS_LONG = %w[arg-file delimiter eof replace max-lines max-args max-procs max-chars process-slot-var].freeze
      URL_TOKEN = %r{[A-Za-z][A-Za-z0-9+.-]*://[^\s"'`<>|;&()]+}

      module_function

      def available?
        true
      end

      def foundation_default?
        false
      end

      def extract(command_text, cwd: nil, git_remote_lookup: nil)
        text = bounded(command_text)
        dir = cwd.is_a?(String) && cwd.start_with?("/") ? cwd : nil
        program = nil
        reaches = []
        Shell.segments(text).each do |segment|
          env, words = Args.split_assignments(segment.words)
          next if words.empty?

          program ||= program_text(words.first)
          if words.first.text == "cd"
            dir = Ops.change_dir(dir, words[1]&.literal) unless %w[| &].include?(segment.separator)
            next
          end
          reaches.concat(command_reaches(words, Context.new(dir, env, git_remote_lookup)))
        end
        { "program" => program, "reaches" => distinct(reaches) }
      end

      def redacted_command(command_text)
        Redact.text(bounded(command_text).gsub(URL_TOKEN) { |url| Redact.url(Targets.sanitize_url(url) || url) })
      end

      def bounded(command_text)
        text = command_text.to_s
        text = text.byteslice(0, Bounds::TOOL_PAYLOAD_BYTES) if text.bytesize > Bounds::TOOL_PAYLOAD_BYTES
        text.scrub("")
      end

      def program_text(word)
        name = Args.program_name(word)
        return nil unless name

        text = Redact.text(name)
        text.bytesize > PROGRAM_BYTES ? text.byteslice(0, PROGRAM_BYTES).scrub("") : text
      end

      def command_reaches(words, ctx)
        words, ctx = unwrap(words, ctx)
        return [] if words.empty?

        handler = HANDLERS[Args.program_name(words.first)]
        return [] unless handler && !words.first.dynamic

        handler.call(words[1..], ctx).filter_map do |place, via, evidence|
          place && { "place" => place, "via_program" => via, "evidence" => evidence }
        end
      rescue StandardError
        []
      end

      def unwrap(words, ctx)
        WRAPPER_DEPTH.times do
          env, words = Args.split_assignments(words)
          ctx = Context.new(ctx.cwd, ctx.env.merge(env), ctx.lookup)
          return [words, ctx] if words.empty? || words.first.dynamic

          case Args.program_name(words.first)
          when "env" then words, ctx = unwrap_env(words[1..], ctx)
          when "sudo" then words, ctx = unwrap_sudo(words[1..], ctx)
          when "nohup" then words = words[1..].drop_while { |word| word.text == "--" }
          when "timeout" then words = unwrap_timeout(words[1..])
          when "xargs" then words = Args.scan(words[1..], short: XARGS_SHORT, optional: XARGS_OPTIONAL, long: XARGS_LONG, interleaved: false).then { |scan| scan.operands + scan.rest }
          else return [words, ctx]
          end
        end
        [[], ctx]
      end

      def unwrap_env(words, ctx)
        scan = Args.scan(words, short: ENV_SHORT, long: ENV_LONG, interleaved: false)
        dir = scan.values("-C", "--chdir").reduce(ctx.cwd) { |current, value| Ops.change_dir(current, value.literal) }
        command = scan.operands + scan.rest
        split = scan.values("-S", "--split-string").last
        if split
          inner = split.literal ? (Shell.segments(split.literal).first&.words || []) : [split]
          command = inner + command
        end
        [command, Context.new(dir, ctx.env, ctx.lookup)]
      end

      def unwrap_sudo(words, ctx)
        scan = Args.scan(words, short: SUDO_SHORT, long: SUDO_LONG, interleaved: false)
        return [[], ctx] if scan.flag?(*SUDO_NO_COMMAND)

        dir = scan.values("-D", "--chdir").reduce(ctx.cwd) { |current, value| Ops.change_dir(current, value.literal) }
        [scan.operands + scan.rest, Context.new(dir, ctx.env, ctx.lookup)]
      end

      def unwrap_timeout(words)
        scan = Args.scan(words, short: TIMEOUT_SHORT, long: TIMEOUT_LONG, interleaved: false)
        (scan.operands + scan.rest).drop(1)
      end

      def distinct(reaches)
        seen = {}
        reaches.each_with_object([]) do |reach, out|
          id = reach["place"]["place_id"]
          next if seen[id]

          seen[id] = true
          out << reach
        end
      end
    end
  end
end
