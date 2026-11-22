# frozen_string_literal: true

module Tellem
  module Places
    module Shell
      Word = Struct.new(:text, :dynamic) do
        def literal
          dynamic ? nil : text
        end
      end
      Segment = Struct.new(:words, :separator)

      SEPARATORS = ["&&", "||", "|&", ";;", ";", "|", "&", "(", ")", "\n"].freeze
      REDIRECTS = ["&>>", "&>", ">>", ">&", ">|", "<<<", "<<-", "<<", "<>", "<&", ">", "<"].freeze
      BLANK = [" ", "\t"].freeze
      OPERATOR_START = ["<", ">", "&", ";", "|", "(", ")", "\n"].freeze

      class Lexer
        def initialize(text)
          @text = text.chars
          @pos = 0
          @segments = []
          @words = []
          @word = nil
          @dynamic = false
          @redirect = false
          @heredocs = []
        end

        def run
          while @pos < @text.length
            char = @text[@pos]
            if BLANK.include?(char)
              finish_word
              @pos += 1
            elsif char == "#" && @word.nil?
              skip_comment
            elsif char == "'" then single_quote
            elsif char == '"' then double_quote
            elsif char == "\\" then escape
            elsif char == "$" then dollar
            elsif char == "`" then backtick
            elsif OPERATOR_START.include?(char) && (op = match_redirect) then redirect(op)
            elsif OPERATOR_START.include?(char) && (op = match_separator) then separate(op)
            else
              append(char)
              @pos += 1
            end
          end
          finish_word
          close_segment(nil)
          @segments
        end

        def append(text, dynamic: false)
          @word = (@word || +"") << text
          @dynamic ||= dynamic
        end

        def finish_word
          return if @word.nil?

          word = Word.new(@word, @dynamic)
          if @redirect
            @heredocs << word if @redirect == :heredoc
            @redirect = false
          else
            @words << word
          end
          @word = nil
          @dynamic = false
        end

        def close_segment(separator)
          @segments << Segment.new(@words, separator) unless @words.empty?
          @words = []
        end

        def skip_comment
          @pos += 1 while @pos < @text.length && @text[@pos] != "\n"
        end

        def single_quote
          close = find("'", @pos + 1) || @text.length
          append(slice(@pos + 1, close))
          @pos = close + 1
        end

        def double_quote
          @pos += 1
          buffer = +""
          dynamic = false
          while @pos < @text.length && @text[@pos] != '"'
            char = @text[@pos]
            if char == "\\" && @pos + 1 < @text.length && ["$", "`", '"', "\\", "\n"].include?(@text[@pos + 1])
              buffer << @text[@pos + 1] unless @text[@pos + 1] == "\n"
              @pos += 2
              next
            end
            dynamic = true if ["$", "`"].include?(char)
            buffer << char
            @pos += 1
          end
          @pos += 1
          append(buffer, dynamic: dynamic)
        end

        def escape
          following = @text[@pos + 1]
          append(following) if following && following != "\n"
          @pos += 2
        end

        def dollar
          following = @text[@pos + 1]
          if following == "(" || following == "{"
            close = balanced(@pos + 1, following, following == "(" ? ")" : "}")
            append(slice(@pos, close), dynamic: true)
            @pos = close
          elsif following == "'"
            @pos += 1
            single_quote
          else
            append("$", dynamic: true)
            @pos += 1
          end
        end

        def backtick
          close = find("`", @pos + 1) || (@text.length - 1)
          append(slice(@pos, close + 1), dynamic: true)
          @pos = close + 1
        end

        def balanced(start, open, close)
          depth = 0
          index = start
          while index < @text.length
            depth += 1 if @text[index] == open
            depth -= 1 if @text[index] == close
            return index + 1 if depth.zero?

            index += 1
          end
          @text.length
        end

        def match_redirect
          op = REDIRECTS.find { |candidate| peek(candidate.length) == candidate }
          return nil unless op
          return nil if op.start_with?("&") && peek(2) == "&&"
          return nil if ["<", ">"].include?(op) && @text[@pos + 1] == "("

          op
        end

        def redirect(op)
          @word = nil if @word&.match?(/\A\d+\z/) && !@dynamic
          finish_word
          @pos += op.length
          if [">&", "<&"].include?(op)
            @pos += 1 while @pos < @text.length && @text[@pos].match?(/[0-9-]/)
            return if @pos >= @text.length || BLANK.include?(@text[@pos]) || match_separator
          end
          @redirect = op.start_with?("<<") && op != "<<<" ? :heredoc : true
        end

        def peek(length)
          @text[@pos, length].to_a.join
        end

        def slice(from, to)
          @text[from...to].to_a.join
        end

        def find(char, from)
          index = from
          while index < @text.length
            return index if @text[index] == char

            index += 1
          end
          nil
        end

        def match_separator
          SEPARATORS.find { |candidate| peek(candidate.length) == candidate }
        end

        def separate(op)
          finish_word
          @pos += op.length
          close_segment(op)
          skip_heredocs if op == "\n" && !@heredocs.empty?
        end

        def skip_heredocs
          @heredocs.each do |delimiter|
            marker = delimiter.text
            loop do
              break if @pos >= @text.length

              stop = find("\n", @pos) || @text.length
              line = slice(@pos, stop)
              @pos = [stop + 1, @text.length].min
              break if line.sub(/\A\t+/, "") == marker
            end
          end
          @heredocs = []
        end
      end

      module_function

      def segments(text)
        Lexer.new(text.to_s.scrub("")).run
      end
    end
  end
end
