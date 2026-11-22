# frozen_string_literal: true

require "time"
require_relative "../record/fs"
require_relative "../record/scope"

module Tellem
  module Backends
    module Lag
      TAIL_PROBE = 65_536

      module_function

      def derived_files(root)
        Record::Scope.session_keys(root).filter_map do |key|
          path = Record::Scope.derived_path(root, key)
          stat = Record::FS.lstat(path)
          stat&.file? ? ["sessions/#{key}/derived.jsonl", path, stat] : nil
        end
      end

      def behind?(path, stat, cursor)
        return stat.size.positive? if cursor.nil?
        return stat.size.positive? unless cursor["inode"].to_i == stat.ino

        offset = cursor["offset"].to_i
        return false if offset >= stat.size
        return true if stat.size - offset > TAIL_PROBE

        tail = File.open(path, File::RDONLY | File::NOFOLLOW) { |file| file.pread(stat.size - offset, offset) }
        tail.include?("\n")
      rescue SystemCallError
        true
      end

      def compute(scopes, cursors, last_sync, extra_root: nil, now: Time.now)
        entries = scopes.map { |row| [row["scope_id"], row["root"]] }
        if extra_root
          extra_id = Record::Scope.scope_id(extra_root)
          entries << [extra_id, extra_root] unless entries.any? { |id, _| id == extra_id }
        end
        per_scope = entries.map do |scope_id, root|
          scope_lag(scope_id, root, cursors.fetch(scope_id, {}), last_sync[scope_id], now)
        end
        lags = per_scope.filter_map { |entry| entry["lag_seconds"] }
        { lag_seconds: lags.max || 0, scopes: per_scope }
      end

      def scope_lag(scope_id, root, cursors, last_sync_at, now)
        unless File.file?(File.join(Record::Scope.dir(root.to_s), "scope.json"))
          return { "scope_id" => scope_id, "root" => root, "gone" => true, "lag_seconds" => nil }
        end

        behind = derived_files(root).reject { |rel, path, stat| !behind?(path, stat, cursors[rel]) }
        lag = if behind.empty?
                0
              elsif last_sync_at
                [(now.to_f - Time.parse(last_sync_at).to_f).round, 1].max
              else
                [(now.to_f - behind.map { |_, _, stat| stat.mtime.to_f }.min).round, 1].max
              end
        { "scope_id" => scope_id, "root" => root, "gone" => false, "files_behind" => behind.size, "lag_seconds" => lag }
      end
    end
  end
end
