# frozen_string_literal: true

require_relative "../../ports/backend"
require_relative "../rows"
require_relative "statements"

module Tellem
  module Backends
    class Mirror < Ports::Backend
      def write_batch(scope_id, batch, cursors: [])
        transaction do
          applied = insert("observations", Rows::OBSERVATION_COLUMNS, batch.map { |record| Rows.observation(scope_id, record) },
                           conflict: %w[scope_id id], cast: body_cast)
          write_usage(scope_id, batch.select { |record| record["kind"] == "usage" })
          apply_details(scope_id, batch)
          places = batch.select { |record| record["kind"] == "place" && record.dig("body", "place_id").is_a?(String) }
                        .map { |record| Rows.place(record) }.uniq(&:first)
          insert("places", Rows::PLACE_COLUMNS, places, conflict: "place_id", update: Rows::PLACE_COLUMNS.drop(1)) unless places.empty?
          superseded = batch.filter_map { |record| record["supersedes"] }.uniq
          unless superseded.empty?
            execute(statement("UPDATE usage SET superseded = %{true} WHERE scope_id = ? AND id IN (%{ids})", ids: superseded.size),
                    [scope_id, *superseded])
          end
          cursors.each { |file, cursor| save_cursor(scope_id, file, cursor) }
          applied
        end
      end

      def write_usage(scope_id, records)
        return if records.empty?

        earliest = {}
        records.each do |record|
          current = earliest[record["id"]]
          earliest[record["id"]] = record if current.nil? || Rows.earlier?(record, current["ts"], current["session_key"])
        end
        ids = earliest.keys
        stored = select(statement("SELECT id, ts, session_key FROM usage WHERE scope_id = ? AND id IN (%{ids})", ids: ids.size),
                        [scope_id, *ids]).to_h { |row| [row["id"], row] }
        fresh = earliest.values.reject { |record| stored.key?(record["id"]) }
        insert("usage", Rows::USAGE_COLUMNS, fresh.map { |record| Rows.usage(scope_id, record) }, conflict: %w[scope_id id])
        earlier = earliest.values.select { |record| (row = stored[record["id"]]) && Rows.earlier?(record, row["ts"], row["session_key"]) }
        insert("usage", Rows::USAGE_COLUMNS, earlier.map { |record| Rows.usage(scope_id, record) },
               conflict: %w[scope_id id], update: Rows::USAGE_COLUMNS - %w[scope_id id superseded])
        mark_usage(scope_id, fresh.map { |record| record["id"] }) unless fresh.empty?
      end

      def mark_usage(scope_id, ids)
        execute(statement("UPDATE usage SET superseded = %{true} WHERE scope_id = ? AND id IN (%{ids}) AND id IN " \
                          "(SELECT o.supersedes FROM observations o WHERE o.scope_id = ? AND o.supersedes IN (%{ids}))", ids: ids.size),
                [scope_id, *ids, scope_id, *ids])
        held = select(statement("SELECT DISTINCT id FROM usage WHERE scope_id <> ? AND id IN (%{ids})", ids: ids.size), [scope_id, *ids])
               .map { |row| row["id"] }
        return if held.empty?

        execute(statement("UPDATE usage SET shared = %{true} WHERE id IN (%{ids})", ids: held.size), held)
      end

      def apply_details(scope_id, batch)
        keys = batch.filter_map { |record| Rows.detail_key(record) if %w[usage usage_detail].include?(record["kind"]) }.uniq
        return if keys.empty?

        keys.map { |harness, request_key| Rows.detail_id(harness, request_key) }.each_slice(ROLLUP_SLICE) do |ids|
          select(statement("SELECT id, body FROM observations WHERE scope_id = ? AND id IN (%{ids})", ids: ids.size),
                 [scope_id, *ids]).sort_by { |row| row["id"] }.each do |row|
            request_key, effort, units = Rows.detail(row["body"])
            next unless request_key

            execute(statement("UPDATE usage SET effort = COALESCE(effort, ?), cost_usd = ? WHERE scope_id = ? AND request_key = ?"),
                    [effort, units, scope_id, request_key])
          end
        end
      end

      def lock_usage
        execute("SELECT pg_advisory_xact_lock(#{USAGE_LOCK})") if kind == "postgres"
      end

      def insert(table, columns, rows, conflict:, update: nil, cast: {})
        return 0 if rows.empty?

        execute(insert_statement(table, columns, rows.size, conflict: conflict, update: update, cast: cast), rows.flatten(1))
      end

      def save_cursor(scope_id, file, cursor)
        insert("sync_cursors", Rows::CURSOR_COLUMNS, [[scope_id, file, cursor["inode"], cursor["offset"]]],
               conflict: %w[scope_id file], update: %w[inode offset])
      end
    end
  end
end
