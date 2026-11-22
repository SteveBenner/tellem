# frozen_string_literal: true

require_relative "options"
require_relative "refresh"
require_relative "scopes"
require_relative "text"

module Tellem
  module Reports
    module Command
      SCOPE_VALUES = %w[--scope].freeze
      SCOPE_FLAGS = %w[--all --strict --no-derive].freeze

      module_function

      def prepare(context, usage:, values: [], flags: [], positional: 0..0)
        options, rest = Options.parse(context.args, usage: usage, values: SCOPE_VALUES + values, flags: SCOPE_FLAGS + flags, positional: positional)
        scope = options[:scope] && File.expand_path(options[:scope])
        scopes = Scopes.resolve(scope: scope, all: options[:all] == true)
        derive = Refresh.run(scopes, strict: options[:strict] == true, skip: options[:no_derive] == true)
        [options, rest, scopes, derive]
      end

      def result(data, text, derive, extra_notes = [])
        { data: data, text: Text.with_notes(text, [Refresh.note(derive), *extra_notes]) }
      end

      def envelope(scopes, derive, body)
        { "scopes" => Scopes.summary(scopes), "derive" => derive }.merge(body)
      end
    end
  end
end
