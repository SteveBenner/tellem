# frozen_string_literal: true

require "json"
require_relative "denied"
require_relative "errors"
require_relative "record/schemas"

module Tellem
  module Commands
  end

  module CLI
    COMMANDS_DIR = File.join(__dir__, "commands")
    NAME = /\A[a-z][a-z_]{0,31}\z/

    Context = Struct.new(:command, :args, :json, :stdout, :stderr, :stdin, keyword_init: true)

    module_function

    def commands
      Dir.glob(File.join(COMMANDS_DIR, "*.rb")).map { |path| File.basename(path, ".rb") }.select { |name| NAME.match?(name) }.sort
    end

    def usage
      "usage: tellem <command> [args] [--json]; commands: #{commands.join(', ')}"
    end

    def run(argv, stdout: $stdout, stderr: $stderr, stdin: $stdin)
      args = argv.dup
      json = !args.delete("--json").nil?
      name = args.shift
      if name.nil?
        stderr.puts(usage)
        return EXIT_CODES[:usage]
      end
      if %w[help --help -h].include?(name)
        stdout.puts(usage)
        return EXIT_CODES[:ok]
      end

      context = Context.new(command: name, args: args, json: json, stdout: stdout, stderr: stderr, stdin: stdin)
      handler = load_command(name)
      return usage_failure(context, "unknown command #{name}") unless handler

      emit(context, handler.run(context))
    rescue Tellem::Error => e
      failure(context || Context.new(command: name, json: json, stdout: stdout, stderr: stderr), e)
    rescue Errno::EACCES, Errno::EPERM => e
      failure(context || Context.new(command: name, json: json, stdout: stdout, stderr: stderr), Denied.failure(e.message))
    end

    def load_command(name)
      return nil unless NAME.match?(name.to_s)

      path = File.join(COMMANDS_DIR, "#{name}.rb")
      return nil unless File.file?(path)

      require path
      const = name.split("_").map(&:capitalize).join
      Commands.const_defined?(const, false) ? Commands.const_get(const, false) : nil
    end

    def emit(context, result)
      return result if result.is_a?(Integer)

      result ||= {}
      data = result.fetch(:data, nil)
      if context.json
        context.stdout.puts(JSON.generate(envelope(context.command, data)))
      else
        text = result[:text] || JSON.pretty_generate(data)
        context.stdout.puts(text) unless text.to_s.empty?
      end
      result.fetch(:exit, EXIT_CODES[:ok])
    end

    def envelope(command, data, error = nil)
      document = { "schema" => Record::Schemas::REPORT, "command" => command, "data" => data }
      document["error"] = error if error
      document
    end

    def usage_failure(context, message)
      failure(context, UsageError.new(message, next_command: "tellem --help"))
    end

    def failure(context, error)
      if context.json
        context.stdout.puts(JSON.generate(envelope(context.command, nil, error.to_h)))
      else
        context.stderr.puts("tellem: #{error.message}")
        context.stderr.puts(usage) if error.is_a?(UsageError)
        context.stderr.puts("next: #{error.next_command}") if error.next_command && !error.is_a?(UsageError)
      end
      error.exit_code
    end
  end
end
