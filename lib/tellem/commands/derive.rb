# frozen_string_literal: true

require_relative "sync"

module Tellem
  module Commands
    module Derive
      USAGE = "derive --scope PATH [--detached]"

      module_function

      def run(context)
        args = context.args.dup
        detached = !args.delete("--detached").nil?
        index = args.index("--scope")
        raise UsageError.new(USAGE) unless index

        path = args[index + 1]
        raise UsageError.new(USAGE) if path.nil? || path.start_with?("-")

        args.slice!(index, 2)
        raise UsageError.new(USAGE) unless args.empty?

        summary = Seams.fetch(:deriver).run(File.expand_path(path), wait: !detached)
        if summary["status"] == "busy"
          raise Busy.new("deriver lock on #{summary['scope_root']} held past #{Deriver::WAIT_S} s",
                         next_command: "tellem sync --scope #{summary['scope_root']}")
        end

        { data: summary, text: Sync.line(summary) }
      end
    end
  end
end
