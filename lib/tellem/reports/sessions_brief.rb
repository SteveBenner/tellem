# frozen_string_literal: true

require_relative "../errors"
require_relative "../ids"
require_relative "../record/formats"
require_relative "options"
require_relative "records"
require_relative "scopes"
require_relative "text"

module Tellem
  module Reports
    module SessionsBrief
      LABEL_CHARS = 80
      MARK = /"kind":"(?:session|lifecycle|task)"/.freeze

      module_function

      def run(scopes, since: nil, limit: nil)
        rows = Scopes.live(scopes).flat_map do |scope|
          Records.derived_files(scope["root"]).map { |key, path| row(scope, key, path) }
        end
        rows = rows.select { |item| (item["started_at"] || item["ended_at"] || "") >= since } if since
        rows = rows.sort_by { |item| [item["started_at"] || item["ended_at"] || "", item["session_key"]] }.reverse
        limit ? rows.first(limit) : rows
      end

      def row(scope, key, path)
        found = { "session" => [], "lifecycle" => [], "task" => [] }
        gone = {}
        Records.each_line_record(path, keep: ->(line) { MARK.match?(line) }) do |record|
          gone[record["supersedes"]] = true if record["supersedes"]
          found[record["kind"]] << record if found.key?(record["kind"]) && record["session_key"] == key
        end
        found.each_value { |list| list.reject! { |record| gone[record["id"]] } }
        body = newest(found["session"])&.fetch("body", nil) || {}
        { "session_key" => key, "root" => scope["root"], "harness" => body["harness"] || key.split("-", 2).first,
          "started_at" => body["started_at"], "ended_at" => ended_at(found["lifecycle"]) || body["ended_at"], "label" => label(found["task"]) }
      end

      def newest(list)
        list.sort_by { |record| Records.sort_key(record) }.reverse.find { |record| Record::Formats.derived_valid?(record) }
      end

      def ended_at(list)
        stopped = list.select { |record| record["agent_key"] == Ids::MAIN_AGENT && record.dig("body", "state") == "stopped" }
        stopped.sort_by { |record| record["ts"].to_s }.reverse.find { |record| Record::Formats.derived_valid?(record) }&.fetch("ts")&.to_s
      end

      def label(tasks)
        first = tasks.select { |record| record["body"].is_a?(Hash) && record.dig("body", "name").is_a?(String) }
                     .sort_by { |record| [record.dig("body", "started").to_f, Records.sort_key(record)] }
                     .find { |record| Record::Formats.derived_valid?(record) }
        name = first && first.dig("body", "name").to_s.strip
        return nil if name.nil? || name.empty?

        name.length > LABEL_CHARS ? name[0, LABEL_CHARS] : name
      end

      def text(rows)
        table = rows.map do |item|
          [item["session_key"], Text.cell(item["root"]), item["harness"].to_s, Text.cell(item["started_at"]), Text.cell(item["ended_at"]), Text.cell(item["label"])]
        end
        Text.table(%w[session root harness started ended label], table)
      end
    end
  end
end
