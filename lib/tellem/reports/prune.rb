# frozen_string_literal: true

require "json"
require "time"
require_relative "../backends/events"
require_relative "../backends/rows"
require_relative "../errors"
require_relative "../ids"
require_relative "../record/formats"
require_relative "../record/fs"
require_relative "../record/lock"
require_relative "../record/pointers"
require_relative "../record/scope"
require_relative "mirror"
require_relative "prune_walk"
require_relative "scopes"

module Tellem
  module Reports
    module Prune
      Rule = Struct.new(:name, :argument, :value, keyword_init: true) do
        def to_s
          "#{name} #{argument}"
        end
      end

      module_function

      def plan(scope, rule, now: Time.now)
        root = scope["root"]
        raise CapabilityUnavailable.new("no tellem scope at #{root}", next_command: "tellem sync --scope #{root}") if scope["gone"]

        candidates = sessions(root) + pointers(root)
        chosen = select(candidates, rule, now).sort_by { |item| item["path"] }
        removed_sessions = chosen.select { |item| item["type"] == "session" }.map { |item| item["name"] }
        mirror = mirror_plan(scope, removed_sessions)
        list = chosen.map { |item| item["path"] }
        list << "mirror:#{mirror['kind']}:#{mirror['location']}:#{mirror['rows']}" if mirror
        {
          "plan_id" => Ids.sha256(Ids.canonical_json([list.sort, rule.to_s]))[0, 12],
          "rule" => rule.to_s, "scope_id" => scope["scope_id"], "root" => root,
          "sessions" => chosen.select { |item| item["type"] == "session" }.map { |item| item.slice("name", "path", "last_at", "bytes") },
          "pointers" => chosen.select { |item| item["type"] == "pointer" }.map { |item| item.slice("name", "path", "last_at", "bytes") },
          "mirror" => mirror, "bytes" => chosen.sum { |item| item["bytes"] }, "kept" => candidates.size - chosen.size
        }
      end

      def sessions(root)
        Record::Scope.session_keys(root).filter_map do |key|
          dir = Record::Scope.session_dir(root, key)
          next unless Record::FS.lstat(dir)&.directory?

          { "type" => "session", "name" => key, "path" => "sessions/#{key}", "absolute" => dir,
            "last" => PruneWalk.last_activity(dir), "bytes" => PruneWalk.tree_bytes(dir) }
        end
      end

      def pointers(root)
        Record::Pointers.names(root).filter_map do |key|
          path = Record::Scope.pointer_path(root, key)
          stat = Record::FS.lstat(path)
          next unless stat&.file?

          pointer = Record::Pointers.read(root, key)
          last = begin
            Time.iso8601(pointer["last_at"].to_s)
          rescue ArgumentError, NoMethodError
            stat.mtime
          end
          { "type" => "pointer", "name" => "#{key}.json", "path" => "pointers/#{key}.json", "absolute" => path, "last" => last, "bytes" => stat.size }
        end
      end

      def select(candidates, rule, now)
        candidates.each { |item| item["last_at"] = item["last"]&.utc&.strftime("%Y-%m-%dT%H:%M:%SZ") }
        if rule.name == "older-than"
          cutoff = now - rule.value
          return candidates.select { |item| item["last"].nil? || item["last"] < cutoff }
        end

        total = candidates.sum { |item| item["bytes"] }
        chosen = []
        candidates.sort_by { |item| [item["last"]&.to_f || 0.0, item["path"]] }.each do |item|
          break if total <= rule.value

          chosen << item
          total -= item["bytes"]
        end
        chosen
      end

      def mirror_plan(scope, session_keys)
        return nil if session_keys.empty?

        adapter = Array(Mirror.adapters([scope])).first
        return nil if adapter.nil? || adapter.kind == "none"

        status = adapter.status
        return nil unless status[:provisioned]
        raise OperationalFailure.new("the #{adapter.kind} mirror is unreachable: #{status[:error]}", next_command: "tellem store status") unless status[:reachable]

        result = adapter.guarded do |_|
          sql = "SELECT COUNT(*) AS n FROM observations WHERE scope_id = #{adapter.ph(1)} AND session_key IN " \
                "(#{Backends::Rows.in_list(session_keys.size, adapter.method(:ph), 1)})"
          adapter.select(sql, [scope["scope_id"], *session_keys]).first["n"].to_i
        end
        raise OperationalFailure.new("counting mirror rows failed: #{result.error}", next_command: "tellem store status") unless result.ok?

        { "kind" => adapter.kind, "location" => adapter.location.to_s, "rows" => result.value }
      end

      def apply(scope, rule, confirm)
        root = scope["root"]
        outcome = Record::Lock.with_lock(root) do
          current = plan(scope, rule)
          unless confirm == current["plan_id"]
            raise ConfirmationRequired.new("confirmation id #{confirm} does not match the current plan #{current['plan_id']}; nothing was removed",
                                           next_command: "tellem prune --#{rule} --scope #{root}", detail: current)
          end

          remove(root, current)
          receipt(root, current)
        end
        raise Busy.new("the deriver holds #{root}; nothing was removed", next_command: "tellem prune --#{rule} --scope #{root}") if outcome == :busy

        outcome
      end

      def remove(root, current)
        scope_dir = Record::Scope.dir(root)
        raise SymlinkRefused.new("symlinked scope refused", detail: { "path" => scope_dir }) unless Record::FS.lstat(scope_dir)&.directory?

        current["sessions"].each { |item| PruneWalk.remove_tree(scope_dir, File.join(scope_dir, item["path"])) }
        current["pointers"].each { |item| PruneWalk.remove_tree(scope_dir, File.join(scope_dir, item["path"])) }
        drop_mirror_rows(current) if current["mirror"]
        Record::FS.fsync_dir(Record::Scope.sessions_dir(root))
        Record::FS.fsync_dir(Record::Scope.pointers_dir(root))
      end

      def drop_mirror_rows(current)
        scope = { "root" => current["root"], "scope_id" => current["scope_id"] }
        adapter = Array(Mirror.adapters([scope])).first
        keys = current["sessions"].map { |item| item["name"] }
        files = keys.map { |key| "sessions/#{key}/derived.jsonl" }
        ph = adapter.method(:ph)
        result = adapter.guarded do |_|
          adapter.transaction do
            %w[usage observations].each do |table|
              adapter.execute("DELETE FROM #{table} WHERE scope_id = #{ph.call(1)} AND session_key IN (#{Backends::Rows.in_list(keys.size, ph, 1)})",
                              [current["scope_id"], *keys])
            end
            adapter.execute("DELETE FROM sync_cursors WHERE scope_id = #{ph.call(1)} AND file IN (#{Backends::Rows.in_list(files.size, ph, 1)})",
                            [current["scope_id"], *files])
          end
        end
        raise OperationalFailure.new("removing mirror rows failed: #{result.error}; rebuild the mirror", next_command: "tellem store rebuild") unless result.ok?
      end

      def receipt(root, current)
        removed = current["sessions"].map { |item| item["name"] } + current["pointers"].map { |item| item["name"] }
        record = Record::Formats.prune_receipt(plan_id: current["plan_id"], rule: current["rule"], removed: removed,
                                               bytes: current["bytes"], at: Record::FS.rfc3339)
        PruneWalk.append_line(Record::Scope.prune_log(root), JSON.generate(record))
        Backends::Events.emit("tellem.prune.applied", { "scope_id" => current["scope_id"], "plan_id" => current["plan_id"],
                                                        "sessions_removed" => current["sessions"].size, "bytes_removed" => current["bytes"] })
        current.merge("applied" => true, "receipt" => record)
      end

      def text(plan)
        lines = ["prune plan #{plan['plan_id']} (#{plan['rule']}) for #{plan['root']}"]
        lines.concat((plan["sessions"] + plan["pointers"]).map { |item| "  remove .tellem/#{item['path']}  #{item['bytes']} bytes  last #{item['last_at'] || '-'}" })
        lines << "  remove #{plan['mirror']['rows']} #{plan['mirror']['kind']} mirror rows at #{plan['mirror']['location']}" if plan["mirror"]
        lines << "  nothing to remove" if plan["sessions"].empty? && plan["pointers"].empty?
        lines << "  total #{plan['bytes']} bytes; #{plan['kept']} kept"
        lines.join("\n")
      end
    end
  end
end
