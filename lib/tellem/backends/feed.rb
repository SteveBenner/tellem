# frozen_string_literal: true

require_relative "../config/resolver"
require_relative "../record/formats"
require_relative "../record/fs"
require_relative "../record/reader"
require_relative "../record/scope"
require_relative "guard"
require_relative "lag"

module Tellem
  module Backends
    class Feed
      def initialize(mirror, scope_root)
        @mirror = mirror
        @root = scope_root
        @totals = { applied: 0, skipped: 0, invalid: 0, torn: 0, batches: 0, failures: 0, attempts: [] }
      end

      def run(force: false)
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        outcome = catch(:stop) { feed_all(force) }
        summary = finish(outcome, started)
        @mirror.emit_synced(summary) unless summary[:skipped_reason]
        summary
      rescue StandardError => e
        { applied: @totals[:applied], skipped: @totals[:skipped], failures: @totals[:failures] + 1, error_class: e.class.name,
          error: @mirror.sanitizer.call(e.message.to_s), breaker: Guard.breaker_state(@mirror.guard_key) }
      end

      private

      def feed_all(force)
        return { skipped_reason: "disabled" } if Guard.disabled?
        return { skipped_reason: "mirror_sync_off" } unless force || Config.get("features.mirror_sync", scope: @root) == true
        return { skipped_reason: "not_provisioned" } unless @mirror.storage_present?

        descriptor = Record::Scope.descriptor(@root)
        @scope_id = descriptor["scope_id"]
        opened = step do
          next :not_provisioned unless @mirror.table_exists?("tellem_meta") && @mirror.meta("schema_version")
          next :schema_ahead if @mirror.ensure_schema == :ahead

          @mirror.insert("scopes", Rows::SCOPE_COLUMNS, [[@scope_id, descriptor["root"], descriptor["kind"]]],
                         conflict: "scope_id", update: %w[root kind])
          load_cursors
        end
        return { skipped_reason: "not_provisioned" } if opened == :not_provisioned
        return { skipped_reason: "schema_ahead" } if opened == :schema_ahead

        @batch = []
        @pending = []
        Lag.derived_files(@root).each { |rel, path, _stat| feed_file(rel, path, opened[rel]) }
        flush
        now = Record::FS.rfc3339
        step do
          @mirror.put_meta("last_sync_at:#{@scope_id}", now)
          @mirror.put_meta("last_sync_at", now)
        end
        Guard.record_sync(@mirror.guard_key, now)
        { done: true }
      end

      def load_cursors
        rows = @mirror.select(%(SELECT file, inode, "offset" FROM sync_cursors WHERE scope_id = #{@mirror.ph(1)}), [@scope_id])
        rows.to_h { |row| [row["file"], { "inode" => row["inode"].to_i, "offset" => row["offset"].to_i }] }
      end

      def feed_file(rel, path, cursor)
        final = Record::Reader.each(path, from: cursor) do |record|
          if Record::Formats.derived_valid?(record)
            @batch << record
          else
            @totals[:invalid] += 1
          end
          flush if @batch.size >= Ports::Backend::SYNC_BATCH
        end
        @totals[:torn] += final["torn"].to_i
        moved = cursor.nil? || cursor["inode"] != final["inode"] || cursor["offset"] != final["offset"]
        @pending << [rel, final] if moved
      end

      def flush
        return if @batch.empty? && @pending.empty?

        batch = @batch
        cursors = @pending
        applied = step { @mirror.write_batch(@scope_id, batch, cursors: cursors) }
        @batch = []
        @pending = []
        @totals[:batches] += 1
        @totals[:applied] += applied
        @totals[:skipped] += batch.size - applied
      end

      def step(&block)
        result = @mirror.guarded { |_| block.call }
        @totals[:attempts].concat(result.attempts)
        return result.value if result.ok?

        @totals[:failures] += 1
        throw :stop, { error: result.error, error_class: result.error_class, breaker: result.breaker, next_command: @mirror.failure_next_command }.compact
      end

      def finish(outcome, started)
        duration = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
        summary = @totals.merge(duration_ms: duration, breaker: Guard.breaker_state(@mirror.guard_key)).merge(outcome)
        summary.delete(:done)
        summary[:lag_seconds] = summary[:error] ? nil : current_lag
        summary
      end

      def current_lag
        return nil unless @scope_id

        result = @mirror.guarded { |_| load_cursors }
        return nil unless result.ok?

        Lag.scope_lag(@scope_id, @root, result.value, Record::FS.rfc3339, Time.now)["lag_seconds"]
      end
    end
  end
end
