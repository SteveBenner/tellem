# frozen_string_literal: true

require "time"
require_relative "../../errors"
require_relative "../../ports/backend"
require_relative "../../ids"
require_relative "../../record/scope"
require_relative "../guard"
require_relative "../lag"
require_relative "statements"

module Tellem
  module Backends
    class Mirror < Ports::Backend
      def status(count: false)
        base = { kind: kind, location: location }
        if Guard.disabled?
          return Ports::Backend.status_record(**base, reachable: false, breaker: "disabled").merge(disabled: true, provisioned: nil)
        end
        unless storage_present?
          return Ports::Backend.status_record(**base, rows: 0, reachable: false, breaker: Guard.breaker_state(guard_key))
                               .merge(disabled: false, provisioned: false)
        end

        result = guarded(breaker: false) { |_| snapshot(count: count) }
        failures = Guard.failures(guard_key)
        if result.ok?
          snap = result.value
          lag = Lag.compute(snap[:scopes], snap[:cursors], snap[:last_sync], extra_root: scope_root)
          state = schema_state(snap[:schema_version])
          if state == "ahead"
            lag = { lag_seconds: nil, scopes: lag[:scopes].map { |entry| entry.merge("lag_seconds" => nil) } }
          end
          record = Ports::Backend.status_record(**base, schema_version: snap[:schema_version], rows: snap[:rows], lag_seconds: lag[:lag_seconds],
                                                last_sync_at: snap[:last_sync_at], reachable: true, breaker: Guard.breaker_state(guard_key))
                                 .merge(disabled: false, provisioned: !snap[:schema_version].nil?, schema_latest: latest_schema, schema_state: state,
                                        failures: failures, scopes: lag[:scopes])
          state == "ahead" ? record.merge(error: ahead_message(snap[:schema_version])) : record
        else
          last = Guard.last_sync_at(guard_key)
          lag = last ? [(Time.now.to_f - Time.parse(last).to_f).round, 0].max : nil
          Ports::Backend.status_record(**base, lag_seconds: lag, last_sync_at: last, reachable: false, breaker: result.breaker)
                        .merge(disabled: false, provisioned: nil, failures: failures, error: result.error)
        end
      end

      def snapshot(count: false)
        return { schema_version: nil, rows: 0, scopes: [], cursors: {}, last_sync: {}, last_sync_at: nil } unless table_exists?("tellem_meta")

        version = meta("schema_version")&.to_i
        rows = count ? select("SELECT COUNT(*) AS n FROM observations").first["n"].to_i : nil
        scopes = select("SELECT scope_id, root, kind FROM scopes")
        cursors = Hash.new { |hash, key| hash[key] = {} }
        select(%(SELECT scope_id, file, inode, "offset" FROM sync_cursors)).each do |row|
          cursors[row["scope_id"]][row["file"]] = { "inode" => row["inode"].to_i, "offset" => row["offset"].to_i }
        end
        last_sync = {}
        select("SELECT key, value FROM tellem_meta WHERE key LIKE 'last_sync_at:%'").each do |row|
          last_sync[row["key"].delete_prefix("last_sync_at:")] = row["value"]
        end
        { schema_version: version, rows: rows, scopes: scopes, cursors: cursors, last_sync: last_sync, last_sync_at: meta("last_sync_at") }
      end

      def rebuild(scopes:)
        raise CapabilityUnavailable.new("TELLEM_BACKEND_DISABLED=1 blocks rebuild", next_command: "unset TELLEM_BACKEND_DISABLED") if Guard.disabled?
        raise CapabilityUnavailable.new("the #{kind} mirror is not provisioned", next_command: "tellem store provision #{kind}") unless storage_present?

        roots = Array(scopes).uniq.select { |root| File.file?(File.join(Record::Scope.dir(root), "scope.json")) }
        @defer_flush = true
        results = begin
          roots.map do |root|
            scope_id = Record::Scope.descriptor(root)["scope_id"]
            cleared = guarded { |_| clear_scope(scope_id) }
            raise OperationalFailure.new("rebuild of #{root} failed: #{cleared.error}", next_command: "tellem store status") unless cleared.ok?

            fed = feed(root, force: true)
            raise OperationalFailure.new("rebuild of #{root} failed: #{fed[:error]}", next_command: "tellem store status") if fed[:error]

            { root: root, scope_id: scope_id, applied: fed[:applied], skipped: fed[:skipped] }
          end
        ensure
          @defer_flush = false
        end
        flushed = guarded { |_| transaction { nil } }
        raise OperationalFailure.new("rebuild failed while recomputing the rollup: #{flushed.error}", next_command: "tellem store rebuild") unless flushed.ok?

        status(count: true).merge(rebuilt: results)
      end

      def known_roots
        result = guarded { |_| table_exists?("scopes") ? select("SELECT root FROM scopes").map { |row| row["root"] } : [] }
        result.ok? ? result.value : []
      end

      def clear_scope(scope_id)
        transaction do
          execute(statement("DELETE FROM usage WHERE scope_id = ?"), [scope_id])
          execute(statement("DELETE FROM observations WHERE scope_id = ?"), [scope_id])
          execute(statement("DELETE FROM sync_cursors WHERE scope_id = ?"), [scope_id])
          execute(statement("DELETE FROM tellem_meta WHERE key = ?"), ["last_sync_at:#{scope_id}"])
        end
      end

      def drop_plan
        current = status(count: true)
        raise OperationalFailure.new("the #{kind} mirror is unreachable: #{current[:error]}", next_command: "tellem store status") if current[:reachable] == false && current[:provisioned].nil?

        identity = [kind, location.to_s, current[:schema_version], current[:rows].to_i]
        { id: Ids.sha256(Ids.canonical_json(identity))[0, 12], kind: kind, location: location, rows: current[:rows].to_i,
          schema_version: current[:schema_version], removes: drop_targets }
      end

      def drop(confirm:)
        raise CapabilityUnavailable.new("TELLEM_BACKEND_DISABLED=1 blocks drop", next_command: "unset TELLEM_BACKEND_DISABLED") if Guard.disabled?

        plan = drop_plan
        unless confirm == plan[:id]
          reason = confirm.nil? ? "store drop removes #{plan[:removes].join(', ')} (#{plan[:rows]} rows)" : "confirmation id #{confirm} does not match the current plan #{plan[:id]}"
          raise ConfirmationRequired.new("#{reason}; plan #{plan[:id]}", next_command: "tellem store drop --confirm #{plan[:id]}",
                                         detail: plan.transform_keys(&:to_s))
        end

        result = guarded { |_| drop_storage }
        raise OperationalFailure.new("drop failed: #{result.error}", next_command: "tellem store status") unless result.ok?

        status.merge(dropped: plan.transform_keys(&:to_s))
      end
    end
  end
end
