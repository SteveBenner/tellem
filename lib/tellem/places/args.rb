# frozen_string_literal: true

module Tellem
  module Places
    module Args
      Option = Struct.new(:name, :value)
      Scan = Struct.new(:options, :operands, :rest) do
        def values(*names)
          options.select { |option| names.include?(option.name) }.map(&:value).compact
        end

        def flag?(*names)
          options.any? { |option| names.include?(option.name) }
        end
      end

      module_function

      def scan(words, short: "", optional: "", long: [], stop_after: nil, interleaved: true)
        options = []
        operands = []
        index = 0
        while index < words.length
          word = words[index]
          text = word.text
          if text == "--"
            operands.concat(words[(index + 1)..])
            index = words.length
            break
          elsif text.start_with?("--") && text.length > 2
            index = long_option(words, index, long, options)
          elsif text.start_with?("-") && text.length > 1
            index = short_option(words, index, short, optional, options)
          else
            operands << word
            index += 1
            break if stop_after && operands.length >= stop_after
            break unless interleaved || stop_after
          end
        end
        Scan.new(options, operands, words[index..] || [])
      end

      def long_option(words, index, long, options)
        name, value = words[index].text[2..].split("=", 2)
        if value.nil? && long.include?(name)
          options << Option.new("--#{name}", words[index + 1])
          index + 2
        else
          options << Option.new("--#{name}", value && Shell::Word.new(value, words[index].dynamic))
          index + 1
        end
      end

      def short_option(words, index, short, optional, options)
        text = words[index].text
        position = 1
        while position < text.length
          letter = text[position]
          attached = text[(position + 1)..].to_s
          if short.include?(letter)
            if attached.empty?
              options << Option.new("-#{letter}", words[index + 1])
              return index + 2
            end
            options << Option.new("-#{letter}", Shell::Word.new(attached, words[index].dynamic))
            return index + 1
          elsif optional.include?(letter)
            options << Option.new("-#{letter}", attached.empty? ? nil : Shell::Word.new(attached, words[index].dynamic))
            return index + 1
          end
          options << Option.new("-#{letter}", nil)
          position += 1
        end
        index + 1
      end

      def assignment?(word)
        word.text.match?(/\A[A-Za-z_][A-Za-z0-9_]*=/)
      end

      def split_assignments(words)
        env = {}
        index = 0
        while index < words.length && assignment?(words[index])
          name, value = words[index].text.split("=", 2)
          env[name] = Shell::Word.new(value, words[index].dynamic)
          index += 1
        end
        [env, words[index..] || []]
      end

      def program_name(word)
        return nil unless word

        name = File.basename(word.text.to_s)
        name.empty? ? nil : name
      end
    end
  end
end
