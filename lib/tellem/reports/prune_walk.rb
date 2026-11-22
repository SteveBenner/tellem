# frozen_string_literal: true

require "time"
require_relative "../errors"
require_relative "../record/fs"
require_relative "records"

module Tellem
  module Reports
    module PruneWalk
      NEWLINE = "\n"

      module_function

      def each_file(dir, &block)
        stat = Record::FS.lstat(dir)
        return unless stat

        if stat.directory?
          Dir.children(dir).sort.each { |name| each_file(File.join(dir, name), &block) }
        else
          yield dir, stat
        end
      end

      def tree_bytes(dir)
        total = 0
        each_file(dir) { |_path, stat| total += stat.size }
        total
      end

      def last_activity(dir)
        newest = nil
        mtime = nil
        each_file(dir) do |path, stat|
          mtime = stat.mtime if mtime.nil? || stat.mtime > mtime
          next unless stat.file? && path.end_with?(".jsonl")

          Records.each_line_record(path) do |record|
            ts = record["ts"]
            newest = ts if ts.is_a?(String) && (newest.nil? || ts > newest)
          end
        end
        newest ? Time.iso8601(newest) : mtime
      rescue ArgumentError
        mtime
      end

      def inside?(scope_dir, path)
        relative = path.delete_prefix("#{scope_dir}/")
        return false if relative == path || relative.split("/").include?("..")

        relative.start_with?("sessions/") || relative.start_with?("pointers/")
      end

      def remove_tree(scope_dir, path)
        raise OperationalFailure.new("prune refused a path outside the scope", detail: { "path" => path }) unless inside?(scope_dir, path)

        stat = Record::FS.lstat(path)
        return 0 unless stat

        if stat.directory?
          Dir.children(path).sort.each { |name| remove_tree(scope_dir, File.join(path, name)) }
          Dir.rmdir(path)
        else
          File.unlink(path)
        end
        1
      end

      def append_line(path, line)
        file = Record::FS.open_append(path)
        begin
          file.flock(File::LOCK_EX)
          size = file.size
          sealed = size.positive? && file.pread(1, size - 1) != NEWLINE
          Record::FS.write_all(file, "#{sealed ? NEWLINE : ''}#{line}#{NEWLINE}")
          file.fsync
          Record::FS.fsync_dir(File.dirname(path)) if size.zero?
        ensure
          file.close
        end
      end
    end
  end
end
