# frozen_string_literal: true

require "json"
require_relative "../ids"
require_relative "../record/kinds"
require_relative "../record/schemas"

module Tellem
  module Backends
    module Rows
      TABLES = %w[sync_cursors places usage_dirty usage_rollup usage observations scopes tellem_meta].freeze
      OBSERVATION_COLUMNS = %w[scope_id id session_key agent_key kind ts schema supersedes body].freeze
      USAGE_COLUMNS = (%w[scope_id id request_key session_key agent_key subagent_type model effort persona repository_id place_id day] +
                       Record::Kinds::COUNTERS + %w[ts superseded]).freeze
      PLACE_COLUMNS = %w[place_id kind host real_path repository_id].freeze
      SCOPE_COLUMNS = %w[scope_id root kind].freeze
      CURSOR_COLUMNS = %w[scope_id file inode offset].freeze
      ROLLUP_DIMENSIONS = %w[agent_key session_key model effort persona repository_id place_id day subagent_type].freeze
      ROLLUP_COUNTS = Record::Kinds::COUNTERS.map { |name| "#{name}_n" }.freeze
      ROLLUP_COLUMNS = (%w[scope_id hour group_key] + ROLLUP_DIMENSIONS + %w[requests] + Record::Kinds::COUNTERS + ROLLUP_COUNTS +
                        %w[cost_usd cost_usd_n]).freeze
      GROUP_KEY_HEX = 24
      DETAIL_KIND = "usage_detail"
      COST_UNITS = 1_000_000_000

      module_function

      def observation(scope_id, record)
        [scope_id, record["id"], record["session_key"], record["agent_key"], record["kind"], record["ts"], record["schema"],
         record["supersedes"], JSON.generate(record["body"] || {})]
      end

      def usage(scope_id, record)
        body = record["body"] || {}
        counters = Record::Kinds::COUNTERS.map { |name| integer(body[name]) }
        [scope_id, record["id"], text(body["request_key"]), record["session_key"], record["agent_key"], text(body["subagent_type"]),
         text(body["model"]), text(body["effort"]), text(body["persona_key"]), text(body["repository_id"]),
         text(body["place_id"]), record["ts"].to_s[0, 10], *counters, record["ts"], false]
      end

      def detail_id(harness, request_key)
        Ids.observation_id(Record::Schemas::DERIVED, DETAIL_KIND, [harness, request_key])
      end

      def detail_key(record)
        body = record["body"] || {}
        harness = text(body["harness"])
        request_key = text(body["request_key"])
        harness && request_key ? [harness, request_key] : nil
      end

      def detail(body)
        body = JSON.parse(body) if body.is_a?(String)
        return nil unless body.is_a?(Hash) && text(body["request_key"])

        [body["request_key"], text(body["effort"]), cost_units(body["cost_usd"])]
      rescue JSON::ParserError
        nil
      end

      def cost_units(value)
        value.is_a?(Numeric) && value.finite? ? (value * COST_UNITS).round : nil
      end

      def cost_usd(units)
        units.nil? ? nil : units.fdiv(COST_UNITS)
      end

      def earlier?(record, ts, session_key)
        ([record["ts"].to_s, record["session_key"].to_s] <=> [ts.to_s, session_key.to_s]).negative?
      end

      def group_key(values)
        Ids.sha256(Ids.canonical_json(values))[0, GROUP_KEY_HEX]
      end

      def hour(ts)
        ts.to_s[0, 13]
      end

      def next_hour(hour)
        time = Time.utc(Integer(hour[0, 4], 10), Integer(hour[5, 2], 10), Integer(hour[8, 2], 10), Integer(hour[11, 2], 10)) + 3600
        time.strftime("%Y-%m-%dT%H")
      end

      def place(record)
        body = record["body"] || {}
        [text(body["place_id"]), text(body["kind"]), text(body["host"]), text(body["real_path"]), text(body["repository_id"])]
      end

      def text(value)
        value.is_a?(String) ? value : nil
      end

      def integer(value)
        value.is_a?(Integer) ? value : nil
      end

      def quote(column)
        %("#{column}")
      end

      def insert_sql(table, columns, count, conflict:, update: nil, placeholder:, cast: {})
        names = columns.map { |column| quote(column) }.join(", ")
        index = 0
        tuples = Array.new(count) do
          values = columns.map do |column|
            index += 1
            mark = placeholder.call(index)
            cast[column] ? "#{mark}#{cast[column]}" : mark
          end
          "(#{values.join(', ')})"
        end
        target = Array(conflict).map { |column| quote(column) }.join(", ")
        action = if update
                   "DO UPDATE SET #{update.map { |column| "#{quote(column)} = excluded.#{quote(column)}" }.join(', ')}"
                 else
                   "DO NOTHING"
                 end
        "INSERT INTO #{table} (#{names}) VALUES #{tuples.join(', ')} ON CONFLICT (#{target}) #{action}"
      end

      def in_list(count, placeholder, offset = 0)
        Array.new(count) { |i| placeholder.call(offset + i + 1) }.join(", ")
      end
    end
  end
end
