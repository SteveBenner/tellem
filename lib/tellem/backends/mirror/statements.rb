# frozen_string_literal: true

require_relative "../../errors"
require_relative "../../record/kinds"
require_relative "../../ports/backend"
require_relative "../rows"

module Tellem
  module Backends
    class Mirror < Ports::Backend
      DIALECT_WORDS = %w[TRUE FALSE 1 0].freeze
      FRAGMENTS = { "true" => :true_word, "false" => :false_word, "unshared" => :unshared_flags,
                    "rollup_select" => :rollup_select, "dimensions" => :rollup_dimensions }.freeze
      TOKEN = /%\{([a-z_]+)\}/.freeze
      MARK = "?"
      COLUMNS = (Rows::OBSERVATION_COLUMNS | Rows::USAGE_COLUMNS | Rows::PLACE_COLUMNS | Rows::SCOPE_COLUMNS |
                 Rows::CURSOR_COLUMNS | Rows::ROLLUP_COLUMNS | %w[key value]).freeze

      def statement(template, lists = {})
        text = template.gsub(TOKEN) do
          name = Regexp.last_match(1)
          method_name = FRAGMENTS[name]
          method_name ? public_send(method_name) : Array.new(lists.fetch(name.to_sym), MARK).join(", ")
        end
        index = 0
        text.gsub(MARK) { ph(index += 1) }
      end

      def true_word
        dialect_word(true_literal)
      end

      def false_word
        dialect_word(false_literal)
      end

      def dialect_word(word)
        raise InvalidInput.new("#{word} is not an allowed SQL dialect word") unless DIALECT_WORDS.include?(word)

        word
      end

      def identifier(name, allowed)
        raise InvalidInput.new("#{name} is not an allowed SQL identifier") unless allowed.include?(name)

        Rows.quote(name)
      end

      def insert_statement(table, columns, count, conflict:, update: nil, cast: {})
        raise InvalidInput.new("#{table} is not an allowed table") unless Rows::TABLES.include?(table)

        named = columns + Array(conflict) + Array(update) + cast.keys
        unknown = named - COLUMNS
        raise InvalidInput.new("#{unknown.join(', ')} are not allowed columns") unless unknown.empty?

        Rows.insert_sql(table, columns, count, conflict: conflict, update: update, placeholder: method(:ph), cast: cast)
      end
    end
  end
end
