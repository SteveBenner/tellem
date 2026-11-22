# frozen_string_literal: true

require_relative "../ids"
require_relative "../redact"

module Tellem
  module Parity
    module Turns
      HEADING = /\A_\*\*(User|Agent)( - sidechain)?(?: \(([^)]*)\))?\*\*_[ \t]*\z/.freeze
      TOOL = /<tool-use\b[^>]*\bdata-tool-name="([^"]*)"/
      TOOL_OPEN = /\A<tool-use[ \t]+data-tool-/.freeze
      TOOL_CLOSE = %r{</tool-use>[ \t]*\z}.freeze
      FENCE = /\A[ \t]{0,3}(`{3,}|~{3,})([^`]*)\z/.freeze
      SEPARATOR = /\A---[ \t]*\z/
      ROLES = { "User" => "user", "Agent" => "agent" }.freeze
      QUEUED = "queued "
      DIGEST_HEX = 16
      REMINDER = %r{<system-reminder>.*?</system-reminder>}m.freeze
      THINKING = %r{<think>.*?</think>}m.freeze
      THINK_OPEN = "<think>"
      MARKER = /\[REDACTED:[^\]\s]*\]/.freeze
      MAX_MATCH_CHARS = 262_144
      MAX_MARKERS = 256
      MAX_STATES = 500_000
      MAX_SPAN = 64
      REDACTION_ONLY = "redaction_only"
      FINAL_REPORT = "subagent_final_report"
      IMAGE_PLACEHOLDER = "image_placeholder"
      INCUMBENT_TRUNCATED = "incumbent_truncated"
      TELLEM_BEHIND = "tellem_behind"
      IMAGE_OMITTED = "[image omitted]"
      HANDBACK_TOOL = "SubagentHandback"

      module_function

      def parse(text)
        turns = []
        current = nil
        inside_tool = false
        fence = nil
        text.to_s.each_line do |line|
          line = line.chomp
          inside_tool = true if !inside_tool && TOOL_OPEN.match?(line)
          match = inside_tool ? nil : HEADING.match(line)
          if match
            turns << finish(current) if current
            current = { "role" => ROLES.fetch(match[1]), "sidechain" => !match[2].nil?, "queued" => match[3].to_s.start_with?(QUEUED),
                        "lines" => [] }
          elsif current && !SEPARATOR.match?(line)
            current["lines"] << line
          end
          fence = inside_tool ? fenced(fence, line) : nil
          inside_tool = false if inside_tool && fence.nil? && TOOL_CLOSE.match?(line)
        end
        turns << finish(current) if current
        turns
      end

      def fenced(fence, line)
        found = FENCE.match(line)
        return fence unless found

        run = found[1]
        return run if fence.nil?

        run[0] == fence[0] && run.size >= fence.size && found[2].strip.empty? ? nil : fence
      end

      def finish(turn)
        body = turn["lines"].join("\n")
        tool = TOOL.match(body)
        text = tool ? nil : normalize(body)
        digest = text && Ids.sha256(text)[0, DIGEST_HEX]
        { "role" => turn["role"], "digest" => digest, "tool" => tool && tool[1], "queued" => turn["queued"],
          "sidechain" => turn["sidechain"], "thinking" => !text.nil? && thinking?(text), "text" => text, "body" => text && body }
      end

      def normalize(text)
        text.to_s.encode("UTF-8", invalid: :replace, undef: :replace).gsub(REMINDER, " ").gsub(/\s+/, " ").strip
      end

      def thinking?(text)
        text.start_with?(THINK_OPEN) && text.gsub(THINKING, "").strip.empty?
      end

      def key(turn)
        [turn["role"], turn["digest"], turn["tool"]]
      end

      def compare(tellem_text, specstory_text, tools: true, subagent: false)
        queued, tellem = parse(tellem_text).partition { |turn| turn["queued"] }
        queued = queued.size
        incumbent = parse(specstory_text)
        unless tools
          tellem = tellem.reject { |turn| turn["tool"] }
          incumbent = incumbent.reject { |turn| turn["tool"] }
        end
        excluded = { "thinking" => incumbent.count { |turn| turn["thinking"] && !turn["sidechain"] },
                     "sidechain" => incumbent.count { |turn| turn["sidechain"] },
                     "tellem_thinking" => tellem.count { |turn| turn["thinking"] && !turn["sidechain"] },
                     "tellem_sidechain" => tellem.count { |turn| turn["sidechain"] } }
        mine_turns = tellem.reject { |turn| turn["thinking"] || turn["sidechain"] }
        theirs_turns = incumbent.reject { |turn| turn["thinking"] || turn["sidechain"] }
        mine = mine_turns.map { |turn| key(turn) }
        theirs = theirs_turns.map { |turn| key(turn) }
        result = { "turns" => { "tellem" => mine.size, "specstory" => theirs.size }, "queued" => queued, "excluded" => excluded }
        return result.merge("verdict" => "match", "causes" => []) if mine == theirs
        return result.merge("verdict" => "match", "causes" => [], "accepted" => [{ "reason" => FINAL_REPORT, "count" => 1 }]) if subagent && final_report_only?(mine_turns, mine, theirs)

        reasons = shared_reasons(mine_turns, theirs_turns)
        if reasons && mine.size >= theirs.size
          reasons[INCUMBENT_TRUNCATED] += mine.size - theirs.size if mine.size > theirs.size
          return result.merge("verdict" => "match", "causes" => [], "accepted" => reasons.map { |reason, count| { "reason" => reason, "count" => count } })
        end

        cause = difference(mine, theirs)
        cause = cause.merge("cause" => TELLEM_BEHIND) if reasons
        result.merge("verdict" => "mismatch", "causes" => [cause])
      end

      def shared_reasons(mine, theirs)
        reasons = Hash.new(0)
        mine.zip(theirs).each do |ours, incumbent|
          next if incumbent.nil? || ours.nil? || key(ours) == key(incumbent)

          reason = accepted_reason(ours, incumbent)
          return nil unless reason

          reasons[reason] += 1
        end
        reasons
      end

      def accepted_reason(ours, incumbent)
        return nil unless ours["role"] == incumbent["role"] && ours["tool"].nil? && incumbent["tool"].nil?

        text = ours["text"]
        return nil unless text && incumbent["text"]

        candidates = [incumbent["text"], normalize(Redact.text(incumbent["body"].to_s))].uniq
        return REDACTION_ONLY if candidates.any? { |other| same?(text, other) }

        stripped = normalize(text.gsub(IMAGE_OMITTED, " "))
        return IMAGE_PLACEHOLDER if stripped != text && candidates.any? { |other| same?(stripped, other) }

        nil
      end

      def same?(ours, incumbent)
        ours == incumbent || redaction_equal?(ours, incumbent)
      end

      def final_report_only?(mine_turns, mine, theirs)
        last = mine_turns.last
        mine.size == theirs.size + 1 && mine.first(theirs.size) == theirs && last["role"] == "agent" && last["tool"] == HANDBACK_TOOL
      end

      def redaction_equal?(a, b)
        return false unless a.size <= MAX_MATCH_CHARS && b.size <= MAX_MATCH_CHARS

        wildcard?(a, b) || wildcard?(b, a) || both_sided?(a, b)
      end

      def both_sided?(one, other)
        left = tokens(one)
        right = tokens(other)
        return false unless left && right && (left.include?(nil) || right.include?(nil))

        expandable?(left, right)
      end

      def tokens(text)
        parts = text.split(MARKER, -1)
        return nil if parts.size > MAX_MARKERS + 1

        parts.each_with_index.flat_map { |part, index| index.zero? ? part.chars : [nil, *part.chars] }
      end

      def expandable?(left, right)
        width = right.size + 1
        base = MAX_SPAN + 1
        seen = {}
        stack = [[0, 0, 0, 0]]
        until stack.empty?
          i, j, inside_left, inside_right = stack.pop
          return true if i == left.size && j == right.size

          key = (((i * width + j) * base) + inside_left) * base + inside_right
          next if seen[key]

          seen[key] = true
          return false if seen.size > MAX_STATES

          stack << [i, j, 0, inside_right] if inside_left.positive?
          stack << [i, j, inside_left, 0] if inside_right.positive?
          step(left, i, inside_left).each do |next_i, next_left, left_char|
            step(right, j, inside_right).each do |next_j, next_right, right_char|
              stack << [next_i, next_j, next_left, next_right] if left_char.nil? || right_char.nil? || left_char == right_char
            end
          end
        end
        false
      end

      def step(tokens, index, inside)
        if inside.positive?
          return inside < MAX_SPAN ? [[index, inside + 1, nil]] : []
        end
        return [] if index >= tokens.size
        return [[index + 1, 1, nil]] if tokens[index].nil?

        [[index + 1, 0, tokens[index]]]
      end

      def wildcard?(pattern_text, other)
        parts = pattern_text.split(MARKER, -1)
        return false if parts.size == 1 || parts.size > MAX_MARKERS + 1

        head, *middle = parts
        tail = middle.pop
        return false unless other.start_with?(head)

        position = head.size
        middle.each do |part|
          found = other.index(part, position + 1)
          return false unless found && found - position <= MAX_SPAN

          position = found + part.size
        end
        span = other.size - tail.size - position
        other.end_with?(tail) && span.positive? && span <= MAX_SPAN
      end

      def difference(mine, theirs)
        shared = [mine.size, theirs.size].min
        index = (0...shared).find { |position| mine[position] != theirs[position] } || shared
        differing = (0...shared).count { |position| mine[position] != theirs[position] }
        {
          "cause" => kind(mine[index], theirs[index]), "first_index" => index, "differing_positions" => differing,
          "length_difference" => mine.size - theirs.size, "tellem" => shown(mine[index]), "specstory" => shown(theirs[index])
        }
      end

      def kind(mine, theirs)
        return "turn_count_differs" if mine.nil? || theirs.nil?
        return "role_differs" if mine[0] != theirs[0]
        return "tool_differs" if mine[2] != theirs[2]

        "text_differs"
      end

      def shown(entry)
        return nil unless entry

        { "role" => entry[0], "digest" => entry[1], "tool" => entry[2] }
      end
    end
  end
end
