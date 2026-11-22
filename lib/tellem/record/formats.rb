# frozen_string_literal: true

require "json"
require_relative "../bounds"
require_relative "../errors"
require_relative "../ids"
require_relative "fs"
require_relative "kinds"
require_relative "schemas"

module Tellem
  module Record
    module Formats
      SCHEMAS = Schemas::ALL
      KINDS = Kinds::NAMES

      RAW_FIELDS = %w[
        harness harness_event event session_id agent_id agent_type cwd tool tool_use_id paths program url_host
        transcript_path agent_transcript_path start_source permission_mode billing outcome payload_bytes over_limit shape missing_keys
        hook_ms tellem_version
      ].freeze
      RAW_EVENTS = %w[session_start prompt_submit post_tool stop session_end subagent_start subagent_stop].freeze
      RAW_REQUIRED = %w[harness harness_event event].freeze
      RAW_ENUMS = {
        "harness" => Ids::HARNESSES,
        "event" => RAW_EVENTS,
        "outcome" => %w[ok error],
        "shape" => %w[known unrecognized]
      }.freeze

      POINTER_KINDS = %w[works_in shells_out_from stands_in].freeze
      SCOPE_KINDS = %w[repository user].freeze
      RFC3339_MS = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z\z/
      RFC3339 = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z\z/
      OBSERVATION_ID = /\A[0-9a-f]{32}\z/

      USAGE_RULES = {
        "claude" => "One provider request per assistant message.id. Content blocks sharing a message.id share one usage; " \
                    "the last occurrence in file order wins and supersedes earlier counters. total_tokens = input_tokens + " \
                    "output_tokens + cache_read_input_tokens + cache_creation_input_tokens. reasoning_tokens is null.",
        "codex" => "One provider request per token_usage_record entry, keyed by its response_id and charged its usage " \
                   "object. Rollouts without token_usage_record fall back to token_count events whose total_token_usage " \
                   "differs from the previous event in the same rollout, keyed <thread_id>:<ordinal> and charged " \
                   "last_token_usage, never the cumulative total. input_tokens includes cached_input_tokens, so " \
                   "cache_read_input_tokens = cached_input_tokens, cache_creation_input_tokens = cache_write_input_tokens, " \
                   "and total_tokens is the provider's total_tokens. reasoning_tokens = reasoning_output_tokens. A forked " \
                   "rollout that repeats earlier records repeats their response_id, so the same request is never charged twice.",
        "general" => "A missing counter is null. Distinct requests with equal numbers stay distinct because request_key, " \
                     "not counters, identifies them."
      }.freeze
      CLAUDE_TOTAL_PARTS = %w[input_tokens output_tokens cache_read_input_tokens cache_creation_input_tokens].freeze
      CODEX_COUNTER_MAP = {
        "input_tokens" => "input_tokens",
        "output_tokens" => "output_tokens",
        "cache_read_input_tokens" => "cached_input_tokens",
        "cache_creation_input_tokens" => "cache_write_input_tokens",
        "reasoning_tokens" => "reasoning_output_tokens",
        "total_tokens" => "total_tokens"
      }.freeze

      module_function

      def raw(fields, ts_ns:, pid:)
        data = stringify(fields)
        unknown = data.keys - RAW_FIELDS
        raise InvalidRecord.new("raw observation has fields outside tellem.raw/v1: #{unknown.sort.join(', ')}") unless unknown.empty?

        RAW_REQUIRED.each { |key| raise InvalidRecord.new("raw observation needs #{key}") if data[key].nil? }
        check_enums(data, RAW_ENUMS)
        data["paths"] = Bounds.clip_paths(data["paths"]) if data.key?("paths")
        data["missing_keys"] = Array(data["missing_keys"]).grep(String) if data.key?("missing_keys")
        agent_key = Ids.agent_key(data["agent_id"]).to_s
        record = {
          "schema" => Schemas::RAW,
          "id" => Ids.raw_id(harness: data["harness"], session_id: data["session_id"].to_s, agent_key: agent_key,
                             event: data["event"], tool_use_id: data["tool_use_id"], ts_ns: ts_ns, pid: pid),
          "ts" => FS.rfc3339_ms(ts_ns)
        }
        RAW_FIELDS.each { |key| record[key] = data[key] }
        record
      end

      def derived(kind:, session_key:, agent_key:, ts:, body:, supersedes: nil)
        spec = Kinds.fetch(kind)
        payload = stringify(body)
        payload["counters_digest"] ||= Ids.counters_digest(payload.slice(*Kinds::COUNTERS)) if kind.to_s == "usage"
        top = { "session_key" => session_key, "agent_key" => agent_key }
        identity = spec[:identity].map do |field|
          value = Kinds::TOP_LEVEL.include?(field) ? top[field] : payload[field]
          raise InvalidRecord.new("#{kind} needs identity field #{field}") if value.nil?

          value
        end
        check_ts(ts)
        check_enums(payload, spec[:enums])
        raise InvalidRecord.new("supersedes must be an observation id") unless supersedes.nil? || OBSERVATION_ID.match?(supersedes)

        {
          "schema" => Schemas::DERIVED,
          "id" => Ids.observation_id(Schemas::DERIVED, kind.to_s, identity),
          "kind" => kind.to_s,
          "ts" => ts,
          "session_key" => session_key,
          "agent_key" => agent_key,
          "supersedes" => supersedes,
          "body" => payload
        }
      end

      def derived_valid?(record)
        return false unless record.is_a?(Hash) && record["schema"] == Schemas::DERIVED && KINDS.include?(record["kind"])

        rebuilt = derived(kind: record["kind"], session_key: record["session_key"], agent_key: record["agent_key"],
                          ts: record["ts"], body: record["body"] || {}, supersedes: record["supersedes"])
        rebuilt["id"] == record["id"]
      rescue Tellem::Error
        false
      end

      def pointer(session_key:, home_scope_id:, home_root:, first_at:, last_at:, kinds:, agents:)
        raise InvalidRecord.new("invalid session key") unless Ids.valid_session_key?(session_key)

        unknown = Array(kinds) - POINTER_KINDS
        raise InvalidRecord.new("pointer kinds outside #{POINTER_KINDS.join(', ')}") unless unknown.empty?

        [first_at, last_at].each { |value| check_rfc3339(value) }
        {
          "schema" => Schemas::POINTER,
          "session_key" => session_key,
          "home_scope_id" => home_scope_id,
          "home_root" => home_root,
          "first_at" => first_at,
          "last_at" => last_at,
          "kinds" => Array(kinds).uniq.sort,
          "agents" => Array(agents).uniq.sort
        }
      end

      def home(root:, scope_id:, kind:, inferred:)
        raise InvalidRecord.new("home kind must be repository or user") unless SCOPE_KINDS.include?(kind)

        { "schema" => Schemas::HOME, "root" => root, "scope_id" => scope_id, "kind" => kind, "inferred" => inferred ? true : false }
      end

      def registry_entry(scope_id:, root:, kind:, first_seen:)
        raise InvalidRecord.new("registry kind must be repository or user") unless SCOPE_KINDS.include?(kind)

        check_rfc3339(first_seen)
        { "scope_id" => scope_id, "root" => root, "kind" => kind, "first_seen" => first_seen }
      end

      def prune_receipt(plan_id:, rule:, removed:, bytes:, at:)
        check_rfc3339(at)
        raise InvalidRecord.new("prune bytes must be an integer") unless bytes.is_a?(Integer)

        { "schema" => Schemas::PRUNE, "plan_id" => plan_id, "rule" => rule, "removed" => Array(removed).sort, "bytes" => bytes, "at" => at }
      end

      def report(command:, data:, error: nil)
        envelope = { "schema" => Schemas::REPORT, "command" => command, "data" => data }
        envelope["error"] = error if error
        envelope
      end

      def stringify(hash)
        return {} if hash.nil?
        raise InvalidRecord.new("record fields must be a mapping") unless hash.is_a?(Hash)

        hash.each_with_object({}) { |(key, value), out| out[key.to_s] = value }
      end

      def check_enums(data, enums)
        enums.each do |field, values|
          value = data[field]
          next if value.nil? || values.include?(value)

          raise InvalidRecord.new("#{field} must be one of #{values.join(', ')}")
        end
      end

      def check_ts(value)
        raise InvalidRecord.new("ts must be RFC 3339 with milliseconds") unless value.is_a?(String) && RFC3339_MS.match?(value)
      end

      def check_rfc3339(value)
        raise InvalidRecord.new("time must be RFC 3339") unless value.is_a?(String) && RFC3339.match?(value)
      end
    end
  end
end
