# frozen_string_literal: true

require "json"
require_relative "../bounds"
require_relative "../record/formats"
require_relative "../record/fs"
require_relative "../record/scope"

module Tellem
  module Reports
    module Records
      NEWLINE = "\n"

      Data = Struct.new(:scope, :records, :places, :session_keys, :torn, keyword_init: true) do
        def of_kind(kind)
          records.select { |record| record["kind"] == kind }
        end

        def for_agent(kind, session_key, agent_key)
          records.select { |record| record["kind"] == kind && record["session_key"] == session_key && record["agent_key"] == agent_key }
        end
      end

      module_function

      def each_line_record(path, keep: nil)
        torn = 0
        Record::FS.open_read(path) do |file|
          file.each_line(NEWLINE) do |line|
            break unless line.end_with?(NEWLINE)
            next if line == NEWLINE
            next if keep && !keep.call(line)

            record = parse(line)
            if record
              yield record
            else
              torn += 1
            end
          end
        end
        torn
      rescue Errno::ENOENT, Errno::ENOTDIR
        torn
      end

      def parse(line)
        return nil if line.bytesize > Bounds::RECORD_BYTES

        record = JSON.parse(line, max_nesting: Bounds::NESTING_DEPTH)
        record.is_a?(Hash) ? record : nil
      rescue JSON::ParserError, EncodingError, ArgumentError
        nil
      end

      def derived_files(root)
        Record::Scope.session_keys(root).filter_map do |key|
          path = Record::Scope.derived_path(root, key)
          Record::FS.lstat(path)&.file? ? [key, path] : nil
        end
      end

      def load(scope)
        root = scope["root"]
        data = assemble(scope, derived_files(root).map { |_key, path| path })
        data.session_keys = Record::Scope.session_keys(root)
        data
      end

      def assemble(scope, paths, session_keys: [], accept: nil)
        seen = {}
        list = []
        superseded = {}
        torn = 0
        paths.each do |path|
          torn += each_line_record(path) do |record|
            next unless Record::Formats.derived_valid?(record)
            next if accept && !accept.call(record)

            superseded[record["supersedes"]] = true if record["supersedes"]
            position = seen[record["id"]]
            if position.nil?
              seen[record["id"]] = list.size
              list << record
            elsif record["kind"] == "usage" && earlier?(record, list[position])
              list[position] = record
            end
          end
        end
        records = list.reject { |record| superseded[record["id"]] }
        places = {}
        records.each do |record|
          next unless record["kind"] == "place"

          places[record.dig("body", "place_id")] ||= record["body"]
        end
        Data.new(scope: scope, records: records, places: places, session_keys: session_keys, torn: torn)
      end

      def earlier?(record, current)
        ([record["ts"].to_s, record["session_key"].to_s] <=> [current["ts"].to_s, current["session_key"].to_s]).negative?
      end

      def place(places, place_id)
        return nil if place_id.nil?

        body = places[place_id]
        return { "place_id" => place_id, "known" => false } unless body

        { "place_id" => place_id, "known" => true, "kind" => body["kind"], "host" => body["host"], "real_path" => body["real_path"],
          "resolved" => body["resolved"], "repository_id" => body["repository_id"] }
      end

      def merged_places(datas)
        datas.each_with_object({}) { |data, out| data.places.each { |id, body| out[id] ||= body } }
      end

      def sort_key(record)
        [record["ts"].to_s, record["kind"].to_s, record["id"].to_s]
      end
    end
  end
end
