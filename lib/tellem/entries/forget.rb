# frozen_string_literal: true

require "json"
require_relative "../backends/events"
require_relative "../errors"
require_relative "../ids"
require_relative "../record/fs"
require_relative "../record/lock"
require_relative "../record/scope"
require_relative "../record/writer"
require_relative "../reports/prune"
require_relative "../reports/prune_walk"

module Tellem
  module Entries
    module Forget
      SCHEMA = "tellem.forget/v1"
      LOG = "forget.jsonl"
      HISTORY = File.join(".specstory", "history")

      module_function

      def log_path(root)
        File.join(Record::Scope.dir(root), LOG)
      end

      def plan(scope, keys, rule)
        root = scope["root"]
        raise CapabilityUnavailable.new("no tellem scope at #{root}", next_command: "tellem sync --scope #{root}") if scope["gone"]

        known = Record::Scope.session_keys(root)
        missing = keys - known
        raise OperationalFailure.new("no session #{missing.first} in #{root}", next_command: "tellem sessions --scope #{root}") unless missing.empty?

        sessions = keys.sort.map { |key| session_plan(root, key) }
        listing = sessions.flat_map { |item| item["files"].map { |file| file["path"] } + item["copies"].map { |file| file["path"] } }
        mirror = Reports::Prune.mirror_plan(scope, keys) unless keys.empty?
        {
          "plan_id" => Ids.sha256(Ids.canonical_json([listing.sort, rule]))[0, 12],
          "rule" => rule, "scope_id" => scope["scope_id"], "root" => root, "sessions" => sessions, "mirror" => mirror,
          "files" => listing.size, "bytes" => sessions.sum { |item| item["bytes"] }
        }
      end

      def session_plan(root, key)
        dir = Record::Scope.session_dir(root, key)
        files = []
        dirs = []
        walk(dir, files, dirs)
        base = Record::Scope.dir(root)
        {
          "name" => key,
          "files" => files.sort_by { |file| file[:path] }.map { |file| { "path" => file[:path].delete_prefix("#{base}/"), "bytes" => file[:bytes] } },
          "dirs" => dirs.sort.reverse.map { |path| path.delete_prefix("#{base}/") },
          "copies" => copies(root, key),
          "bytes" => files.sum { |file| file[:bytes] }
        }
      end

      def walk(dir, files, dirs)
        stat = Record::FS.lstat(dir)
        raise OperationalFailure.new("forget refused a path that is not a plain directory", detail: { "path" => dir }) unless stat&.directory?

        dirs << dir
        Dir.children(dir).sort.each do |name|
          path = File.join(dir, name)
          child = Record::FS.lstat(path)
          if child&.directory?
            walk(path, files, dirs)
          elsif child&.file?
            files << { path: path, bytes: child.size }
          else
            raise OperationalFailure.new("forget refused a path that is neither a file nor a directory", detail: { "path" => path })
          end
        end
      end

      def copies(root, key)
        dir = Record::Scope.transcripts_dir(root, key)
        return [] unless Record::FS.lstat(dir)&.directory?

        Dir.children(dir).sort.filter_map do |name|
          source = File.join(dir, name)
          target = File.join(root, HISTORY, name)
          next unless name.end_with?(".md") && Record::FS.lstat(source)&.file? && identical?(source, target)

          { "path" => File.join(HISTORY, name), "bytes" => Record::FS.lstat(target).size }
        end
      end

      def identical?(source, target)
        left = Record::FS.lstat(source)
        right = Record::FS.lstat(target)
        right&.file? && left.size == right.size && Record::FS.read(source) == Record::FS.read(target)
      end

      def apply(scope, keys, rule, confirm, command)
        root = scope["root"]
        outcome = Record::Lock.with_lock(root) do
          current = plan(scope, keys, rule)
          unless confirm == current["plan_id"]
            raise ConfirmationRequired.new("confirmation id #{confirm} does not match the current plan #{current['plan_id']}; nothing was removed",
                                           next_command: command, detail: current)
          end

          remove(root, current)
        end
        raise Busy.new("the deriver holds #{root}; nothing was removed", next_command: command) if outcome == :busy

        outcome
      end

      def remove(root, current)
        base = Record::Scope.dir(root)
        raise SymlinkRefused.new("symlinked scope refused", detail: { "path" => base }) unless Record::FS.lstat(base)&.directory?

        receipts = current["sessions"].map { |item| forget_session(root, base, item, current["plan_id"], current["rule"]) }
        Reports::Prune.drop_mirror_rows(current) if current["mirror"]
        drop_cursor(root, current["sessions"].map { |item| item["name"] })
        Record::FS.fsync_dir(Record::Scope.sessions_dir(root))
        Backends::Events.emit("tellem.forget.applied", { "scope_id" => current["scope_id"], "plan_id" => current["plan_id"],
                                                         "sessions_removed" => current["sessions"].size, "bytes_removed" => current["bytes"] })
        current.merge("applied" => true, "receipts" => receipts)
      end

      def forget_session(root, base, item, plan_id, rule)
        removed = item["files"].filter_map { |file| unlink(File.join(base, file["path"])) ? file["path"] : nil }
        copies = item["copies"].filter_map { |file| unlink(File.join(root, file["path"])) ? file["path"] : nil }
        dirs = item["dirs"].filter_map { |path| rmdir(File.join(base, path)) ? path : nil }
        receipt = { "schema" => SCHEMA, "plan_id" => plan_id, "rule" => rule, "session_key" => item["name"], "removed" => removed,
                    "removed_copies" => copies, "removed_dirs" => dirs, "bytes" => item["bytes"], "at" => Record::FS.rfc3339,
                    "remaining" => (item["files"].size - removed.size) + (item["dirs"].size - dirs.size) }
        Reports::PruneWalk.append_line(log_path(root), JSON.generate(receipt))
        receipt
      end

      def unlink(path)
        stat = Record::FS.lstat(path)
        return false unless stat&.file?

        File.unlink(path)
        true
      end

      def rmdir(path)
        return false unless Record::FS.lstat(path)&.directory?

        Dir.rmdir(path)
        true
      rescue Errno::ENOTEMPTY, Errno::EEXIST
        false
      end

      def drop_cursor(root, keys)
        path = Record::Scope.cursor_file(root)
        data = begin
          JSON.parse(Record::FS.read(path))
        rescue Errno::ENOENT, JSON::ParserError
          nil
        end
        return unless data.is_a?(Hash) && data["sessions"].is_a?(Hash)

        removed = keys.map { |key| data["sessions"].delete(key) }
        Record::Writer.replace_if_changed(path, "#{JSON.generate(data)}\n") if removed.any?
      end

      def text(plan)
        lines = ["forget plan #{plan['plan_id']} (#{plan['rule']}) for #{plan['root']}"]
        plan["sessions"].each do |item|
          lines << "  session #{item['name']}: #{item['files'].size} files, #{item['bytes']} bytes"
          lines.concat(item["files"].map { |file| "    remove .tellem/#{file['path']}  #{file['bytes']} bytes" })
          lines.concat(item["copies"].map { |file| "    remove #{file['path']}  #{file['bytes']} bytes (identical copy)" })
        end
        lines << "  remove #{plan['mirror']['rows']} #{plan['mirror']['kind']} mirror rows at #{plan['mirror']['location']}" if plan["mirror"]
        lines << "  nothing to remove" if plan["sessions"].empty?
        lines << "  total #{plan['files']} files, #{plan['bytes']} bytes"
        lines.join("\n")
      end
    end
  end
end
