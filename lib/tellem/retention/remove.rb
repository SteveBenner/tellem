# frozen_string_literal: true

require "digest"
require "json"
require_relative "../authority/switch"
require_relative "../errors"
require_relative "../ids"
require_relative "../record/fs"
require_relative "../record/reader"
require_relative "../record/schemas"
require_relative "../record/scope"
require_relative "../deriver/emit"

module Tellem
  module Retention
    module Remove
      SCHEMA = "tellem.retention/v1"
      LOG = "retention.jsonl"
      NEWLINE = "\n"
      PENDING = "pending"
      APPLIED = "applied"
      RECEIPT_ID_HEX = 16
      NS = 1_000_000_000

      module_function

      def log_path(root)
        File.join(Record::Scope.dir(root), LOG)
      end

      def run(context, result, window_days, transcript_root)
        return "authority_stopped" if Authority::Switch.off?

        session = result.session
        session.raw_paths.each_value { |path| Record::FS.flush(path) }
        Record::FS.fsync_file(Record::Scope.cursor_file(context.root))
        return "changed_during_removal" if result.files.any? { |file| moved?(file) }

        hashed = result.files.map { |file| file.merge(digest(file["path"])) }
        return "changed_during_removal" if result.files.any? { |file| moved?(file) }

        main = hashed.first
        ordered = hashed.drop(1) + [main]
        pending = pending(context, result, ordered, window_days)
        outcome = complete(context, pending, transcript_root, resumed: false)
        outcome["kept"].empty? ? nil : "changed_during_removal"
      end

      def pending(context, result, files, window_days, method: nil)
        paths = files.map { |file| file.slice("path", "bytes", "sha256", "inode", "size", "mtime_ns") }
        id = Ids.sha256(Ids.canonical_json([context.scope_id, result.session_key, paths, Record::FS.now_ns]))[0, RECEIPT_ID_HEX]
        receipt = {
          "schema" => SCHEMA, "phase" => PENDING, "receipt_id" => id, "at" => Record::FS.rfc3339, "scope_id" => context.scope_id,
          "session_key" => result.session_key, "window_days" => window_days, "requests" => result.requests,
          "counters" => result.counters, "paths" => paths, "dirs" => result.dirs
        }
        receipt["method"] = method if method
        write_line(log_path(context.root), JSON.generate(receipt))
        receipt
      end

      def close_codex(context, receipt, success)
        removed, kept = Array(receipt["paths"]).partition { |item| !Record::FS.lexists?(item["path"]) }
        applied = {
          "schema" => SCHEMA, "phase" => APPLIED, "receipt_id" => receipt["receipt_id"], "at" => Record::FS.rfc3339, "scope_id" => receipt["scope_id"],
          "session_key" => receipt["session_key"], "resumed" => false, "method" => receipt["method"], "delete_ok" => success,
          "removed" => removed.map { |item| item.slice("path", "bytes", "sha256") }, "kept" => kept.map { |item| item.slice("path", "bytes", "sha256").merge("cause" => "codex_delete") },
          "dirs" => [], "partial" => !success || !kept.empty?
        }
        write_line(log_path(context.root), JSON.generate(applied))
        Deriver::Emit.emit("tellem.retention.applied", {
                             "scope_id" => receipt["scope_id"], "session_key" => receipt["session_key"], "files" => removed.size,
                             "bytes" => removed.sum { |item| item["bytes"].to_i }, "partial" => applied["partial"], "resumed" => false
                           })
        applied
      end

      def complete(context, receipt, transcript_root, resumed:)
        removed = []
        kept = []
        Array(receipt["paths"]).each do |item|
          case unlink_verified(item, transcript_root, deep: resumed)
          when :removed then removed << item.slice("path", "bytes", "sha256")
          when :absent then removed << item.slice("path", "bytes", "sha256").merge("absent" => true)
          else kept << item.slice("path", "bytes", "sha256").merge("cause" => "changed")
          end
        end
        dirs = Array(receipt["dirs"]).select { |dir| rmdir(dir, transcript_root) || !Record::FS.lexists?(dir) }
        applied = {
          "schema" => SCHEMA, "phase" => APPLIED, "receipt_id" => receipt["receipt_id"], "at" => Record::FS.rfc3339,
          "scope_id" => receipt["scope_id"], "session_key" => receipt["session_key"], "resumed" => resumed,
          "removed" => removed, "kept" => kept, "dirs" => dirs, "partial" => !kept.empty? || dirs.size != Array(receipt["dirs"]).size
        }
        write_line(log_path(context.root), JSON.generate(applied))
        Deriver::Emit.emit("tellem.retention.applied", {
                             "scope_id" => receipt["scope_id"], "session_key" => receipt["session_key"], "files" => removed.size,
                             "bytes" => removed.sum { |file| file["bytes"].to_i }, "partial" => applied["partial"], "resumed" => resumed
                           })
        applied
      end

      def unlink_verified(item, transcript_root, deep:)
        path = item["path"]
        stat = Record::FS.lstat(path)
        return :absent unless stat
        return :changed if stat.symlink? || !stat.file? || !inside?(File.dirname(path), transcript_root)
        return :changed unless same?(stat, item)
        return :changed if deep && digest(path) != item.slice("bytes", "sha256")

        Record::FS.refuse_target_symlink(path)
        File.unlink(path)
        :removed
      rescue SymlinkRefused, Errno::ENOENT
        :changed
      end

      def same?(stat, item)
        stat.ino == item["inode"] && stat.size == item["size"] && (stat.mtime.to_r * NS).to_i == item["mtime_ns"]
      end

      def inside?(path, root)
        File.realpath(path).start_with?("#{root}/")
      rescue Errno::ENOENT, Errno::ENOTDIR, Errno::EACCES
        false
      end

      def digest(path)
        sha = Digest::SHA256.new
        bytes = 0
        Record::FS.open_read(path) do |file|
          while (chunk = file.read(1 << 20))
            sha.update(chunk)
            bytes += chunk.bytesize
          end
        end
        { "bytes" => bytes, "sha256" => sha.hexdigest }
      end

      def moved?(file)
        stat = Record::FS.lstat(file["path"])
        return true unless stat&.file?

        !same?(stat, file)
      end

      def rmdir(dir, transcript_root)
        stat = Record::FS.lstat(dir)
        return false unless stat&.directory? && !stat.symlink? && inside?(dir, transcript_root)

        Dir.rmdir(dir)
        Record::FS.fsync_dir(File.dirname(dir))
        true
      rescue Errno::ENOTEMPTY, Errno::EEXIST, Errno::ENOENT, Errno::EACCES
        false
      end

      def write_line(path, line)
        Record::FS.mkdir_p(File.dirname(path))
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

      def receipts(root)
        path = log_path(root)
        return [] unless Record::FS.lexists?(path)

        list = []
        Record::Reader.each(path) { |record| list << record if record["schema"] == SCHEMA }
        list
      end

      def open_receipts(root)
        list = receipts(root)
        closed = list.select { |record| record["phase"] == APPLIED }.to_h { |record| [record["receipt_id"], true] }
        list.select { |record| record["phase"] == PENDING && !closed[record["receipt_id"]] }
      end

      def resume(context, transcript_root)
        return [] if Authority::Switch.off?

        open_receipts(context.root).filter_map do |receipt|
          receipt["method"] ? close_codex(context, receipt, false) : complete(context, receipt, transcript_root, resumed: true)
        end
      end
    end
  end
end
