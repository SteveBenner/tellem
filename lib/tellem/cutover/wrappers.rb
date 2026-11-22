# frozen_string_literal: true

require_relative "../errors"

module Tellem
  module Cutover
    module Wrappers
      ROLE = "wrapper"
      KIND = "wrapper"

      module_function

      def found(report)
        report["methods"].select { |entry| entry["kind"] == KIND && entry["state"] == "present" && entry.dig("facts", "lines") }
      end

      def plan(build, report)
        routes = {}
        found(report).group_by { |entry| target(entry) }.each do |real, entries|
          route = entries.first.dig("facts", "file")
          routes[real] = [KIND]
          ordered = entries.sort_by { |entry| -entry.dig("facts", "lines").first }
          build.edit(real, ROLE, outside: real) do |text|
            ordered.inject([text, []]) do |(current, changes), entry|
              updated, change = remove(current, entry["facts"])
              [updated, changes + change]
            end
          end
          build.note(real, "the wrapper in #{route} changed since discovery") unless build.entry_for(real)
        end
        routes
      end

      def target(entry)
        facts = entry["facts"]
        real = facts["real_path"].is_a?(String) ? facts["real_path"] : facts["file"]
        File.join(File.realpath(File.dirname(real)), File.basename(real))
      end

      def remove(text, facts)
        from, to = facts["lines"]
        lines = text.lines
        first = lines[from - 1].to_s
        return [text, []] unless first.b.include?(facts["name"].to_s.b) && to <= lines.size

        kept = lines[0...(from - 1)] + lines[to..]
        [kept.join, ["remove #{facts['shape']} #{facts['name']} (lines #{from}-#{to})"]]
      end
    end
  end
end
