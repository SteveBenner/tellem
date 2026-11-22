# frozen_string_literal: true

require_relative "../../record/kinds"
require_relative "../../ports/backend"
require_relative "../rows"
require_relative "statements"

module Tellem
  module Backends
    class Mirror < Ports::Backend
      def recompute_rollup
        execute("DELETE FROM usage_rollup")
        rows = select(statement("SELECT scope_id, SUBSTR(ts, 1, 13) AS hour, %{rollup_select} FROM usage WHERE %{unshared} " \
                                "GROUP BY scope_id, SUBSTR(ts, 1, 13), %{dimensions}"))
        insert_rollup(rows)
      end

      def flush_dirty
        return nil if @defer_flush || !table_exists?("usage_dirty")

        dirty = select("SELECT scope_id, hour FROM usage_dirty").map { |row| [row["scope_id"], row["hour"]] }
        return nil if dirty.empty?

        execute("DELETE FROM usage_dirty")
        recomputed = dirty.sum { |scope_id, hour| recompute_bucket(scope_id, hour) }
        { buckets: dirty.size, rows: recomputed }
      end

      def recompute_bucket(scope_id, hour)
        execute(statement("DELETE FROM usage_rollup WHERE scope_id = ? AND hour = ?"), [scope_id, hour])
        rows = select(statement("SELECT scope_id, SUBSTR(ts, 1, 13) AS hour, %{rollup_select} FROM usage WHERE %{unshared} " \
                                "AND scope_id = ? AND ts >= ? AND ts < ? GROUP BY scope_id, SUBSTR(ts, 1, 13), %{dimensions}"),
                      [scope_id, hour, Rows.next_hour(hour)])
        insert_rollup(rows)
        rows.sum { |row| row["requests"].to_i }
      end

      def rollup_dimensions
        Rows::ROLLUP_DIMENSIONS.map { |name| identifier(name, Rows::ROLLUP_DIMENSIONS) }.join(", ")
      end

      def rollup_select
        sums = Record::Kinds::COUNTERS.map do |name|
          column = identifier(name, Record::Kinds::COUNTERS)
          "CAST(COALESCE(SUM(#{column}), 0) AS BIGINT) AS #{column}"
        end
        counts = Record::Kinds::COUNTERS.map do |name|
          "COUNT(#{identifier(name, Record::Kinds::COUNTERS)}) AS #{identifier("#{name}_n", Rows::ROLLUP_COUNTS)}"
        end
        cost = ["CAST(COALESCE(SUM(cost_usd), 0) AS BIGINT) AS cost_usd", "COUNT(cost_usd) AS cost_usd_n"]
        "#{rollup_dimensions}, COUNT(*) AS requests, #{(sums + counts + cost).join(', ')}"
      end

      def unshared_flags
        "shared = #{false_word} AND superseded = #{false_word}"
      end

      def insert_rollup(rows)
        tuples = rows.map do |row|
          values = Rows::ROLLUP_DIMENSIONS.map { |name| row[name] }
          [row["scope_id"], row["hour"], Rows.group_key(values), *values, row["requests"].to_i,
           *Record::Kinds::COUNTERS.map { |name| row[name].to_i }, *Rows::ROLLUP_COUNTS.map { |name| row[name].to_i },
           row["cost_usd"].to_i, row["cost_usd_n"].to_i]
        end
        tuples.each_slice(ROLLUP_SLICE) do |slice|
          execute(insert_statement("usage_rollup", Rows::ROLLUP_COLUMNS, slice.size, conflict: %w[scope_id hour group_key]), slice.flatten(1))
        end
        tuples.size
      end
    end
  end
end
