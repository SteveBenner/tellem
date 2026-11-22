# frozen_string_literal: true

module Tellem
  module Discovery
    module Toml
      HEADER = /\A\s*(\[\[?)\s*(.+?)\s*\]\]?\s*(?:#.*)?\z/.freeze
      PART = /\G\s*(?:"((?:[^"\\]|\\.)*)"|'([^']*)'|([A-Za-z0-9_-]+))\s*(?:\.|\z)/.freeze
      ASSIGN = /\A\s*("(?:[^"\\]|\\.)*"|'[^']*'|[A-Za-z0-9_.-]+)\s*=\s*(.*)\z/.freeze

      module_function

      def entries(text)
        section = []
        pending = nil
        found = []
        text.each_line.with_index(1) do |line, number|
          if pending
            pending = nil if closes?(line, pending)
            next
          end
          stripped = line.strip
          next if stripped.empty? || stripped.start_with?("#")

          if (match = HEADER.match(stripped))
            section = path(match[2])
            found << { section: section, key: nil, value: nil, line: number, array: match[1] == "[[" }
            next
          end
          assign = ASSIGN.match(stripped)
          next unless assign

          key = unquote(assign[1])
          raw = assign[2]
          pending = opener(raw)
          found << { section: section, key: key, value: scalar(raw), line: number, array: false }
        end
        found
      end

      def path(text)
        parts = []
        offset = 0
        while offset < text.length && (match = PART.match(text, offset))
          parts << (match[1] || match[2] || match[3])
          offset = match.end(0)
          break if match[0].strip.empty?
        end
        parts
      end

      def unquote(token)
        token.start_with?('"', "'") ? token[1..-2] : token
      end

      def opener(raw)
        return '"""' if raw.start_with?('"""') && raw.scan('"""').size == 1
        return "'''" if raw.start_with?("'''") && raw.scan("'''").size == 1
        return "[" if raw.start_with?("[") && raw.count("[") > raw.count("]")

        nil
      end

      def closes?(line, opener)
        opener == "[" ? line.include?("]") : line.include?(opener)
      end

      def scalar(raw)
        value = raw.sub(/\s+#.*\z/, "").strip
        case value
        when "true" then true
        when "false" then false
        when /\A-?\d+\z/ then value.to_i
        when /\A"((?:[^"\\]|\\.)*)"\z/ then Regexp.last_match(1).gsub(/\\(.)/, '\1')
        when /\A'([^']*)'\z/ then Regexp.last_match(1)
        else :complex
        end
      end

      def table(entries, prefix)
        entries.select { |entry| entry[:key] && entry[:section].first(prefix.size) == prefix }
      end
    end
  end
end
