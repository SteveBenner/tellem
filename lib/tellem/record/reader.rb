# frozen_string_literal: true

require "json"
require_relative "../bounds"
require_relative "fs"

module Tellem
  module Record
    module Reader
      NEWLINE = "\n"

      module_function

      def each(path, from: nil, limit_bytes: Bounds::RECORD_BYTES)
        cursor = { "inode" => nil, "offset" => 0, "torn" => 0, "records" => 0, "partial_tail" => false }
        FS.open_read(path) do |file|
          stat = file.stat
          cursor["inode"] = stat.ino
          offset = start_offset(from, stat)
          file.seek(offset)
          file.each_line(NEWLINE) do |line|
            unless line.end_with?(NEWLINE)
              cursor["partial_tail"] = true
              break
            end
            offset += line.bytesize
            record = parse(line, limit_bytes)
            if record
              cursor["records"] += 1
              yield record if block_given?
            elsif line != NEWLINE
              cursor["torn"] += 1
            end
          end
          cursor["offset"] = offset
        end
        cursor
      rescue Errno::ENOENT
        cursor
      end

      def records(path, from: nil)
        list = []
        cursor = each(path, from: from) { |record| list << record }
        [list, cursor]
      end

      def ids(path)
        seen = {}
        each(path) { |record| seen[record["id"]] = true if record["id"].is_a?(String) }
        seen
      end

      def start_offset(from, stat)
        return 0 unless from.is_a?(Hash)

        inode = from["inode"] || from[:inode]
        offset = (from["offset"] || from[:offset]).to_i
        return 0 unless inode == stat.ino
        return 0 if offset.negative? || offset > stat.size

        offset
      end

      def parse(line, limit_bytes)
        return nil if line.bytesize > limit_bytes

        record = JSON.parse(line, max_nesting: Bounds::NESTING_DEPTH)
        record.is_a?(Hash) ? record : nil
      rescue JSON::ParserError, EncodingError, ArgumentError
        nil
      end
    end
  end
end
