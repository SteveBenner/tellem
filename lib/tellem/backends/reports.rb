# frozen_string_literal: true

require_relative "../errors"
require_relative "../ports/backend"
require_relative "../record/kinds"
require_relative "rows"

module Tellem
  module Backends
    module Reports
      ANSWERS = %w[tokens].freeze
      COUNTERS = Record::Kinds::COUNTERS
      TOKEN_DIMENSIONS = {
        "agent" => "u.agent_key",
        "session" => "u.session_key",
        "model" => "u.model",
        "effort" => "u.effort",
        "persona" => "u.persona",
        "repository" => "u.repository_id",
        "place" => "u.place_id",
        "day" => "u.day",
        "subagent_type" => "u.subagent_type",
        "type" => "u.subagent_type"
      }.freeze

      module_function

      def answers?(report)
        ANSWERS.include?(report.to_s)
      end

      def run(mirror, report, params)
        raise Ports::Backend::Declined.new("the mirror does not answer report #{report}") unless answers?(report)

        tokens(mirror, stringify(params))
      end

      def stringify(params)
        params.each_with_object({}) { |(key, value), out| out[key.to_s] = value }
      end

      def dimensions(params)
        dims = Array(params["by"]).flat_map { |value| value.to_s.split(",") }.map(&:strip).reject(&:empty?)
        dims = ["model"] if dims.empty?
        unknown = dims - TOKEN_DIMENSIONS.keys
        raise UsageError.new("unknown token dimension #{unknown.join(', ')}; known: #{TOKEN_DIMENSIONS.keys.join(', ')}") unless unknown.empty?

        dims.uniq
      end

      def tokens(mirror, params)
        dims = dimensions(params)
        binds = []
        bind = lambda do |value|
          binds << value
          mirror.ph(binds.size)
        end
        groups = dims.map { |dim| TOKEN_DIMENSIONS.fetch(dim) }
        names = dims.map { |dim| Rows.quote(dim) }
        select = groups.zip(names).map { |(group, name)| "#{group} AS #{name}" }
        sums = COUNTERS.map { |name| "SUM(u.#{name}) AS #{name}" } + ["SUM(u.cost_usd) AS cost_usd", "COUNT(u.cost_usd) AS cost_usd_n"]
        group_by = " GROUP BY #{groups.join(', ')}"
        unshared = ["u.shared = #{flag(mirror, false)}", "u.superseded = #{flag(mirror, false)}"]
        window = hours(params["since"], params["until"])
        parts = []
        if window[:rollup]
          lo, hi = window[:rollup]
          where = scoped(params, bind)
          where << "u.hour >= #{bind.call(lo)}" if lo
          where << "u.hour < #{bind.call(hi)}" if hi
          rolled = (COUNTERS + ["cost_usd"]).map { |name| "CASE WHEN SUM(u.#{name}_n) > 0 THEN SUM(u.#{name}) END AS #{name}" } +
                   ["SUM(u.cost_usd_n) AS cost_usd_n"]
          parts << "SELECT #{(select + ['SUM(u.requests) AS requests'] + rolled).join(', ')} FROM usage_rollup u#{clause(where)}#{group_by}"
        end
        window[:raw].each do |(from, to)|
          where = unshared + scoped(params, bind)
          where << "u.ts >= #{bind.call(from)}" if from
          where << "u.ts < #{bind.call(to)}" if to
          parts << "SELECT #{(select + ['COUNT(*) AS requests'] + sums).join(', ')} FROM usage u#{clause(where)}#{group_by}"
        end
        shared_where = ["u.shared = #{flag(mirror, true)}"] + scoped(params, bind)
        shared_where << "u.ts >= #{bind.call(params['since'].to_s)}" if params["since"]
        shared_where << "u.ts < #{bind.call(params['until'].to_s)}" if params["until"]
        ranked = "SELECT u.*, ROW_NUMBER() OVER (PARTITION BY u.id ORDER BY #{order(mirror, 'u.scope_id')}) AS tellem_rank, " \
                 "MAX(CASE WHEN u.superseded THEN 1 ELSE 0 END) OVER (PARTITION BY u.id) AS tellem_superseded FROM usage u#{clause(shared_where)}"
        parts << "SELECT #{(select + ['COUNT(*) AS requests'] + sums).join(', ')} FROM (#{ranked}) u " \
                 "WHERE u.tellem_rank = 1 AND u.tellem_superseded = 0#{group_by}"
        outer = names.map { |name| "t.#{name}" }
        totals = (COUNTERS + %w[cost_usd cost_usd_n]).map { |name| "CAST(SUM(t.#{name}) AS BIGINT) AS #{name}" }
        sql = "SELECT #{(outer.zip(names).map { |(column, name)| "#{column} AS #{name}" } + ['CAST(SUM(t.requests) AS BIGINT) AS requests'] + totals).join(', ')} " \
              "FROM (#{parts.join(' UNION ALL ')}) t GROUP BY #{outer.join(', ')} " \
              "ORDER BY #{outer.map { |column| "#{order(mirror, column)} ASC NULLS FIRST" }.join(', ')}"
        costs(mirror.select(sql, binds).map { |row| normalize(row, dims) })
      end

      def costs(rows)
        any = rows.any? { |row| row["cost_usd_n"].to_i.positive? }
        rows.each do |row|
          units = row.delete("cost_usd")
          count = row.delete("cost_usd_n").to_i
          row["cost_usd"] = count.positive? ? Rows.cost_usd(units) : nil if any
        end
      end

      def hours(since, before)
        since = since&.to_s
        before = before&.to_s
        lo = since && (since <= "#{Rows.hour(since)}:00:00" ? Rows.hour(since) : Rows.next_hour(Rows.hour(since)))
        hi = before && Rows.hour(before)
        return { rollup: nil, raw: [[since, before]] } if lo && hi && lo >= hi

        raw = []
        raw << [since, lo] if since
        raw << [hi, before] if before
        { rollup: [lo, hi], raw: raw }
      end

      def scoped(params, bind)
        where = []
        where << "u.session_key = #{bind.call(params['session'].to_s)}" if params["session"]
        scope_ids = Array(params["scope_ids"]).map(&:to_s)
        where << "u.scope_id IN (#{scope_ids.map { |id| bind.call(id) }.join(', ')})" unless scope_ids.empty?
        where
      end

      def clause(where)
        where.empty? ? "" : " WHERE #{where.join(' AND ')}"
      end

      def flag(mirror, value)
        if mirror.kind == "postgres"
          value ? "TRUE" : "FALSE"
        else
          value ? "1" : "0"
        end
      end

      def order(mirror, expression)
        mirror.kind == "postgres" ? %(#{expression} COLLATE "C") : expression
      end

      def normalize(row, dims)
        out = {}
        dims.each { |dim| out[dim] = row[dim] }
        out["requests"] = integer(row["requests"])
        COUNTERS.each { |name| out[name] = row[name].nil? ? nil : integer(row[name]) }
        out["cost_usd"] = row["cost_usd"].nil? ? nil : integer(row["cost_usd"])
        out["cost_usd_n"] = row["cost_usd_n"].nil? ? 0 : integer(row["cost_usd_n"])
        out
      end

      def integer(value)
        value.is_a?(Integer) ? value : Integer(value.to_s, 10)
      end
    end
  end
end
