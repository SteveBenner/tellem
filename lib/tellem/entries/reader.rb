# frozen_string_literal: true

require_relative "../errors"
require_relative "../ids"
require_relative "../record/fs"
require_relative "../record/pointers"
require_relative "../record/reader"
require_relative "../record/scope"
require_relative "store"

module Tellem
  module Entries
    module Reader
      CURSOR = /\Ae1:(?:[A-Za-z0-9_-]{1,128}=\d{1,12}(?:,[A-Za-z0-9_-]{1,128}=\d{1,12})*)?\z/.freeze
      CURSOR_PREFIX = "e1:"
      FIELDS = %w[cursor session_key agent_key seq kind at tool call_id text part withheld note source].freeze

      module_function

      def load(root, session_key)
        folder = Store.dir(root, session_key)
        stat = Record::FS.lstat(folder)
        return {} unless stat&.directory?

        Dir.children(folder).sort.each_with_object({}) do |name, out|
          agent = name.delete_suffix(".jsonl")
          next unless name.end_with?(".jsonl") && Ids.valid_agent_key?(agent)

          path = File.join(folder, name)
          next unless Record::FS.lstat(path)&.file?

          out[agent] = agent_records(path)
        end
      end

      def home_root(root, key)
        return root if Record::FS.lstat(Record::Scope.session_dir(root, key))&.directory?

        pointer = Record::Pointers.read(root, key)
        home = pointer && pointer["home_root"]
        home if home.is_a?(String) && Record::FS.lstat(Record::Scope.session_dir(home, key))&.directory?
      end

      def agent_records(path)
        seen = {}
        records, = Record::Reader.records(path)
        records.select do |record|
          valid = record["schema"] == SCHEMA && record["id"].is_a?(String) && record["seq"].is_a?(Integer) && !seen[record["id"]]
          seen[record["id"]] = true if valid
          valid
        end.sort_by { |record| record["seq"] }
      end

      def parse_cursor(value)
        return {} if value.nil? || value.empty?
        raise UsageError.new("malformed cursor #{value.inspect}", next_command: "tellem export --session KEY") unless CURSOR.match?(value)

        value.delete_prefix(CURSOR_PREFIX).split(",").to_h do |pair|
          agent, seq = pair.split("=", 2)
          [agent, seq.to_i]
        end
      end

      def format_cursor(position)
        pairs = position.select { |_agent, seq| seq.positive? }.sort.map { |agent, seq| "#{agent}=#{seq}" }
        "#{CURSOR_PREFIX}#{pairs.join(',')}"
      end

      def page(by_agent, after: nil, limit: nil)
        position = parse_cursor(after)
        queues = by_agent.to_h { |agent, records| [agent, records.drop_while { |record| record["seq"] <= position.fetch(agent, 0) }] }
        entries = []
        loop do
          break if limit && entries.size >= limit

          agent, record = head(queues)
          break unless agent

          queues[agent].shift
          position[agent] = record["seq"]
          entries << shape(record, format_cursor(position))
        end
        remaining = queues.values.sum(&:size)
        { "entries" => entries, "next_cursor" => entries.empty? ? format_cursor(parse_cursor(after)) : entries.last["cursor"],
          "more" => remaining.positive? }
      end

      def head(queues)
        best = nil
        queues.each do |agent, list|
          candidate = list.first
          next unless candidate

          best = [agent, candidate] if best.nil? || (order(agent, candidate) <=> order(*best)).negative?
        end
        best
      end

      def order(agent, record)
        [record["at"].to_s, agent, record["seq"]]
      end

      def shape(record, cursor)
        FIELDS.to_h { |field| [field, field == "cursor" ? cursor : record[field]] }
      end
    end
  end
end
