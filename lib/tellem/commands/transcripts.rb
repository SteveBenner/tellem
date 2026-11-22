# frozen_string_literal: true

require_relative "../errors"
require_relative "../ports/harness_paths"
require_relative "../discovery"

module Tellem
  module Commands
    module Transcripts
      USAGE = "tellem transcripts discover [--json]"

      module_function

      def run(context)
        args = context.args.dup
        raise UsageError.new(USAGE) unless args.shift == "discover" && args.empty?

        report = Tellem::Discovery.run(Ports::HarnessPaths.discovery_paths)
        { data: report, text: text(report) }
      end

      def text(report)
        lines = ["digest #{report['digest']}"]
        report["harnesses"].each do |harness|
          lines << "#{harness['id']}: #{harness['installed'] ? "version #{harness['version'] || 'unknown'}" : 'not installed'}, binary scan #{harness.dig('binary', 'scan')}"
        end
        report["methods"].group_by { |entry| entry["kind"] }.sort.each do |kind, entries|
          states = entries.group_by { |entry| entry["state"] }.map { |state, same| "#{same.size} #{state}" }.join(", ")
          lines << "#{kind}: #{states}"
        end
        lines << "readers: #{report['readers'].size}"
        report["readers"].each { |reader| lines << "  #{reader['id']} (#{reader['kind']}, #{reader['confidence']})" }
        lines.join("\n")
      end
    end
  end
end
