# frozen_string_literal: true

require "json"
require_relative "../config/resolver"
require_relative "../entries/reader"
require_relative "../errors"
require_relative "../ids"
require_relative "../record/fs"
require_relative "../record/pointers"
require_relative "../record/scope"
require_relative "../reports/options"
require_relative "../reports/scopes"
require_relative "../seams"

module Tellem
  module Commands
    module Export
      USAGE = "tellem export --session KEY [--after CURSOR] [--limit N] [--scope PATH] [--json]"

      module_function

      def run(context)
        options, = Reports::Options.parse(context.args, usage: USAGE, values: %w[--session --after --limit --scope])
        key = options[:session]
        raise UsageError.new(USAGE) unless Ids.valid_session_key?(key)

        limit = integer(options[:limit], "--limit")
        root = Reports::Scopes.root_for(File.expand_path(options[:scope] || Dir.pwd))
        home = home_root(root, key)
        page = Entries::Reader.page(Entries::Reader.load(home, key), after: options[:after], limit: limit)
        enabled = Config.get("transcripts.entries", scope: home) == true
        data = { "session_key" => key, "scope_root" => home, "enabled" => enabled }.merge(page)
        { data: data, text: page["entries"].map { |entry| JSON.generate(entry) }.join("\n") }
      end

      def integer(value, name)
        return nil if value.nil?

        number = Integer(value, 10)
        raise ArgumentError unless number.positive?

        number
      rescue ArgumentError
        raise UsageError.new("#{name} must be a positive integer: #{USAGE}")
      end

      def home_root(root, key)
        Entries::Reader.home_root(root, key) ||
          raise(CapabilityUnavailable.new("no session #{key} in #{root}", next_command: "tellem sync --session #{key} --scope #{root}"))
      end
    end
  end
end
