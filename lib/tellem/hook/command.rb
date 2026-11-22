# frozen_string_literal: true

module Tellem
  module Hook
    module Command
      ASSIGNMENT = /\A[A-Za-z_][A-Za-z0-9_]*=/
      BREAKS = [" ", "\t", "\n", "\r", ";", "&", "|", "<", ">", "(", ")"].freeze
      PROGRAM_BYTES = 255

      module_function

      def program(command)
        words = command.is_a?(Array) ? command.grep(String) : leading_words(command)
        word = words.find { |item| !ASSIGNMENT.match?(item) }
        return nil if word.nil? || word.empty?

        name = File.basename(word)
        name.empty? || name.bytesize > PROGRAM_BYTES ? nil : name
      end

      def leading_words(text)
        return [] unless text.is_a?(String)

        words = []
        index = 0
        loop do
          index += 1 while index < text.length && [" ", "\t", "\r", "\n"].include?(text[index])
          word, index = read_word(text, index)
          return words if word.nil?

          words << word
          return words unless ASSIGNMENT.match?(word)
        end
      end

      def read_word(text, index)
        word = +""
        quote = nil
        started = false
        while index < text.length
          char = text[index]
          if quote == "'"
            if char == "'"
              quote = nil
            else
              word << char
            end
          elsif quote == "\""
            if char == "\""
              quote = nil
            elsif char == "\\" && index + 1 < text.length
              index += 1
              word << text[index]
            else
              word << char
            end
          elsif BREAKS.include?(char)
            break
          elsif char == "'" || char == "\""
            quote = char
          elsif char == "\\" && index + 1 < text.length
            index += 1
            word << text[index]
          else
            word << char
          end
          started = true
          index += 1
        end
        [started ? word : nil, index]
      end

      def url_host(url)
        return nil unless url.is_a?(String)

        authority = url[%r{\A[A-Za-z][A-Za-z0-9+.\-]*://([^/?#]*)}, 1]
        return nil if authority.nil?

        hostport = authority.split("@").last.to_s
        host = hostport.start_with?("[") ? hostport[/\A\[[^\]]*\]/] : hostport.split(":").first
        host.nil? || host.empty? ? nil : host.downcase
      end
    end
  end
end
