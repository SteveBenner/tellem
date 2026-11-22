# frozen_string_literal: true

require_relative "../ids"
require_relative "../record/formats"
require_relative "../record/reader"
require_relative "../record/scope"
require_relative "../record/writer"

module Tellem
  module Deriver
    class Session
      STOP_EVENTS = %w[stop session_end].freeze
      SETTLE_S = 35

      attr_reader :context, :key, :harness, :session_id, :raw, :fresh, :raw_paths, :raw_entries, :natives, :batches,
                  :home, :standing, :links, :calls
      attr_accessor :failed
      attr_reader :unsettled

      def initialize(context, key)
        @context = context
        @key = key
        @harness, @session_id = key.split("-", 2)
        @raw = {}
        @fresh = []
        @raw_paths = {}
        @raw_entries = {}
        @natives = {}
        @batches = {}
        @home = {}
        @standing = Hash.new { |hash, agent| hash[agent] = [] }
        @links = {}
        @calls = {}
        @pending = []
        @ids = {}
        @by_kind = Hash.new { |hash, kind| hash[kind] = [] }
        @places = {}
        @failed = nil
        @unsettled = false
        @settle_cutoff = Record::FS.rfc3339_ms(context.started_ns - (SETTLE_S * 1_000_000_000))
        load_existing
      end

      def root
        context.root
      end

      def load_existing
        records, = Record::Reader.records(Record::Scope.derived_path(root, key))
        records.each { |record| index(record) if record["schema"] == Record::Schemas::DERIVED && record["id"].is_a?(String) }
      end

      def index(record)
        return false if @ids.key?(record["id"])

        @ids[record["id"]] = true
        @by_kind[record["kind"]] << record
        body = record["body"]
        @places[body["place_id"]] ||= body if record["kind"] == "place" && body.is_a?(Hash)
        true
      end

      def known?(id)
        @ids.key?(id)
      end

      def of(kind)
        @by_kind[kind]
      end

      def add(kind, agent_key:, ts:, body:, supersedes: nil)
        record = Record::Formats.derived(kind: kind, session_key: key, agent_key: agent_key, ts: ts, body: body,
                                         supersedes: supersedes)
        return nil unless index(record)

        @pending << record
        record
      end

      def flush
        return { "appended" => 0, "gaps" => [] } if @pending.empty?

        result = Record::Writer.append_derived(root, key, @pending)
        gaps = @pending.select { |record| record["kind"] == "gap" }
        @pending = []
        result.merge("gaps" => gaps)
      end

      def all_raw
        @all_raw ||= raw.values.flatten.sort_by { |record| [record["ts"], record["id"]] }
      end

      def raw_agent(id)
        @raw_agent ||= raw.flat_map { |agent, records| records.map { |record| [record["id"], agent] } }.to_h
        @raw_agent[id]
      end

      def agent_keys
        (raw.keys + batches.keys).uniq.sort_by { |agent| [agent == Ids::MAIN_AGENT ? 0 : 1, agent] }
      end

      def stops
        @stops ||= all_raw.select { |record| STOP_EVENTS.include?(record["event"]) }.map { |record| record["ts"] }
      end

      def session_end
        all_raw.find { |record| record["event"] == "session_end" }
      end

      def first_ts
        times = all_raw.map { |record| record["ts"] } + batches.values.filter_map(&:started_at)
        times.min
      end

      def place_for(place_id)
        @places[place_id]
      end

      def add_place(body, agent_key:, ts:)
        return nil unless body.is_a?(Hash) && body["place_id"]

        known = @places[body["place_id"]]
        return known if known

        add("place", agent_key: agent_key, ts: ts, body: body)
        add_repository(body, agent_key, ts)
        body
      end

      def local_place(path, agent_key:, ts:, base: nil)
        return nil unless path.is_a?(String) && !path.empty?

        quick = context.resolve(path, base: base, repository: false)
        known = @places[quick["place_id"]]
        return known if known

        add_place(context.resolve(path, base: base), agent_key: agent_key, ts: ts)
      end

      def add_repository(place, agent_key, ts)
        repository_id = place["repository_id"]
        return unless repository_id && place["real_path"]
        return if of("repository").any? { |record| record["body"]["repository_id"] == repository_id }

        probe = File.directory?(place["real_path"]) ? place["real_path"] : File.dirname(place["real_path"])
        record = context.repository(probe)
        add("repository", agent_key: agent_key, ts: ts, body: record) if record && record["repository_id"] == repository_id
      end

      def standing_at(agent_key, ts)
        entries = standing[agent_key]
        return nil if entries.empty?

        found = entries.reverse.find { |entry| entry[0] <= ts.to_s }
        (found || entries.first)[1]
      end

      def gap(cause, location, agent_key:, ts:, detail: {}, count: 1, harness_version: nil)
        add("gap", agent_key: agent_key, ts: ts, body: {
              "cause" => cause, "location" => location, "harness" => harness, "harness_version" => harness_version,
              "detail" => detail, "count" => count
            })
      end

      def harness_version
        batch = batches[Ids::MAIN_AGENT] || batches.values.first
        batch&.harness_version
      end

      def overdue?(ts)
        return false unless ts.is_a?(String)
        return true if ts < @settle_cutoff

        @unsettled = true
        false
      end

      def stopped?
        !session_end.nil?
      end
    end
  end
end
