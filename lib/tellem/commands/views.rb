# frozen_string_literal: true

module Tellem
  module Commands
    module Views
      USAGE = "views rebuild [--check] [--scope PATH]"

      module_function

      def run(context)
        args = context.args.dup
        raise UsageError.new(USAGE) unless args.shift == "rebuild"

        check = !args.delete("--check").nil?
        scope = option(args, "--scope")
        raise UsageError.new(USAGE) unless args.empty?

        root = Record::Scope.locate(scope || Dir.pwd)
        unless Record::FS.lstat(Record::Scope.dir(root))&.directory?
          raise CapabilityUnavailable.new("no tellem scope at #{root}", next_command: "tellem sync --scope #{root}")
        end

        summary = Seams.fetch(:projections).refresh(root, force: true, check: check)
        raise CapabilityUnavailable.new("projections are not built", next_command: "tellem doctor") if summary.nil?

        data = summary.merge("check" => check)
        exit_code = check && summary["changed"] ? EXIT_CODES[:operational_failure] : EXIT_CODES[:ok]
        { data: data, text: text(data), exit: exit_code }
      end

      def option(args, name)
        index = args.index(name)
        return nil unless index

        value = args[index + 1]
        raise UsageError.new(USAGE) if value.nil? || value.start_with?("-")

        args.slice!(index, 2)
        File.expand_path(value)
      end

      def text(data)
        tokens = data["tokens"]
        story = data["specstory"]
        verb = data["check"] ? "would change" : "changed"
        lines = ["scope #{data['scope']}"]
        lines << "TOKENS.jsonl: #{tokens['rows']} rows, #{tokens['changed'] ? verb : 'unchanged'} (#{tokens['path']})"
        if story["enabled"]
          lines << "SpecStory: #{story['copies']} copies, #{story['changed'].size} #{verb} (#{story['dir']})"
          story["conflicts"].each { |conflict| lines << "  conflict: #{conflict['name']} also in #{conflict['session_key']}" }
        else
          lines << "SpecStory: not written (#{story['reason']})"
        end
        lines.join("\n")
      end
    end
  end
end
