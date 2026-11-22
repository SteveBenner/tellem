# frozen_string_literal: true

require "json"
require_relative "../bounds"
require_relative "../errors"
require_relative "fs"
require_relative "reader"
require_relative "schemas"
require_relative "scope"

module Tellem
  module Record
    module Writer
      NEWLINE = "\n"

      module_function

      def append_derived(scope_root, session_key, records)
        path = Scope.derived_path(scope_root, session_key)
        FS.mkdir_p(File.dirname(path))
        append_unique(path, Array(records))
      end

      def append_unique(path, records)
        records.each { |record| check_record(record) }
        FS.mkdir_p(File.dirname(path))
        file = FS.open_append(path)
        begin
          file.flock(File::LOCK_EX)
          seen = Reader.ids(path)
          fresh = []
          records.each do |record|
            next if seen[record["id"]]

            seen[record["id"]] = true
            fresh << record
          end
          return { "appended" => 0, "skipped" => records.size } if fresh.empty?

          size = file.size
          sealed = size.positive? && file.pread(1, size - 1) != NEWLINE
          body = fresh.map { |record| encode(record) }.join(NEWLINE)
          FS.write_all(file, "#{sealed ? NEWLINE : ''}#{body}#{NEWLINE}")
          file.fsync
          FS.fsync_dir(File.dirname(path)) if size.zero?
          { "appended" => fresh.size, "skipped" => records.size - fresh.size }
        ensure
          file.close
        end
      end

      def encode(record)
        line = JSON.generate(record)
        Bounds.check_bytes(line.bytesize + 1, :record_bytes)
        line
      end

      def check_record(record)
        raise InvalidRecord.new("record must be a mapping with a string id") unless record.is_a?(Hash) && record["id"].is_a?(String)
      end

      def replace_atomic(path, bytes)
        FS.mkdir_p(File.dirname(path))
        FS.replace(path, bytes)
      end

      def replace_if_changed(path, bytes)
        current = begin
          FS.read(path)
        rescue Errno::ENOENT
          nil
        end
        return false if current == bytes

        replace_atomic(path, bytes)
        true
      end
    end
  end
end
