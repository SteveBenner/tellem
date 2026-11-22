# frozen_string_literal: true

module Tellem
  module Cutover
    module Callers
      PYTHON = /\.py\z/
      BLOCK_IF = /\A(\s*)if\b.*:\s*\z/
      DEF = /\A(\s*)def\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(.*\)\s*(?:->\s*[^:]+)?:\s*\z/
      DISABLED = "return None"
      ASSIGNMENT = /\A\s*[A-Za-z_][A-Za-z0-9_.]*\s*=[^=]/
      BRANCH = /\A\s*(?:elif\b|else\s*:)/

      module_function

      def python?(rel)
        PYTHON.match?(rel)
      end

      def edit(text, hook_names)
        lines = text.lines
        changes = []
        disabled = []
        loop do
          index = lines.each_index.find { |position| calls?(lines[position], hook_names) && !inside_disabled?(lines, position, disabled) }
          break unless index

          change = cut(lines, index, hook_names, disabled)
          break unless change

          changes << change
        end
        [lines.join, changes]
      end

      def remaining(text, hook_names)
        lines = text.lines
        disabled = lines.each_index.select { |index| lines[index].strip == DISABLED && DEF.match?(lines[index - 1].to_s) }.map { |index| index - 1 }
        lines.each_index.select { |index| mentions?(lines[index], hook_names) && !inside_disabled?(lines, index, disabled) }.map { |index| index + 1 }
      end

      def calls?(line, hook_names)
        hook_names.any? { |name| line.include?("\"#{name}\"") || line.include?("'#{name}'") }
      end

      def mentions?(line, hook_names)
        hook_names.any? { |name| line.include?(name) }
      end

      def cut(lines, index, hook_names, disabled)
        start = index
        parent = parent_of(lines, start)
        return nil unless parent

        name = hook_names.find { |hook| lines[index].include?(hook) }
        finish = statement_end(lines, start)
        if BLOCK_IF.match?(lines[parent]) && block_end(lines, parent) == finish && !continued?(lines, finish, indent(lines[parent]))
          condition = lines[parent].strip
          lines.slice!(parent..finish)
          return "remove the #{name} call under `#{condition}`"
        end
        unless ASSIGNMENT.match?(lines[start])
          lines[start..finish] = ["#{' ' * indent(lines[start])}pass\n"]
          return "replace the #{name} call with pass"
        end
        definition = enclosing_def(lines, parent)
        return nil unless definition

        lines.insert(definition + 1, "#{body_indent(lines, definition)}#{DISABLED}\n")
        disabled << definition
        "#{DEF.match(lines[definition])[2]}() returns before it runs #{name}"
      end

      def continued?(lines, finish, level)
        following = ((finish + 1)...lines.size).find { |position| !blank?(lines[position]) }
        !following.nil? && indent(lines[following]) == level && BRANCH.match?(lines[following])
      end

      def indent(line)
        line[/\A */].length
      end

      def blank?(line)
        line.strip.empty?
      end

      def statement_end(lines, start)
        level = indent(lines[start])
        last = start
        ((start + 1)...lines.size).each do |position|
          next if blank?(lines[position])
          break if indent(lines[position]) <= level

          last = position
        end
        last
      end

      def block_end(lines, parent)
        statement_end(lines, parent)
      end

      def parent_of(lines, start)
        level = indent(lines[start])
        (start - 1).downto(0).find { |position| !blank?(lines[position]) && indent(lines[position]) < level }
      end

      def enclosing_def(lines, from)
        position = from
        while position
          return position if DEF.match?(lines[position])

          position = parent_of(lines, position)
        end
        nil
      end

      def body_indent(lines, definition)
        following = ((definition + 1)...lines.size).find { |position| !blank?(lines[position]) }
        " " * (following ? indent(lines[following]) : indent(lines[definition]) + 4)
      end

      def inside_disabled?(lines, index, disabled)
        disabled.any? { |definition| index > definition && index <= block_end(lines, definition) }
      end
    end
  end
end
