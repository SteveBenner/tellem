# frozen_string_literal: true

require_relative "../errors"

module Tellem
  module Record
    module Kinds
      TOP_LEVEL = %w[session_key agent_key].freeze

      COUNTERS = %w[input_tokens output_tokens cache_read_input_tokens cache_creation_input_tokens reasoning_tokens total_tokens].freeze

      USAGE_ATTRIBUTION = %w[subagent_type effort persona persona_key repository_id place_id].freeze

      USAGE_PROVIDER_EXTRAS = %w[
        stop_reason cache_creation_ephemeral_1h_input_tokens cache_creation_ephemeral_5m_input_tokens
        server_tool_use_web_search_requests server_tool_use_web_fetch_requests
      ].freeze

      USAGE_LEDGER = %w[
        first_line_at first_line_uuid inference_geo speed permission_mode billing ledger_id cwd
      ].freeze

      TABLE = {
        "session" => {
          identity: %w[session_key],
          body: %w[harness harness_version host home_place_id started_at ended_at],
          enums: { "harness" => %w[claude codex] }
        },
        "agent" => {
          identity: %w[session_key agent_key],
          body: %w[parent_agent_key spawn_tool_use_id agent_type model effort isolation home_place_id evidence],
          enums: { "isolation" => %w[shared worktree] }
        },
        "place" => {
          identity: %w[place_id],
          body: %w[place_id kind host real_path resolved repository_id attributes],
          enums: {
            "kind" => %w[local host container cluster domain remote_repository],
            "resolved" => %w[full partial missing]
          }
        },
        "repository" => {
          identity: %w[repository_id],
          body: %w[repository_id host common_dir remotes],
          enums: {}
        },
        "stands_in" => {
          identity: %w[session_key agent_key place_id first_raw_id],
          body: %w[place_id first_raw_id from to],
          enums: {}
        },
        "works_in" => {
          identity: %w[source_id place_id],
          body: %w[source_id place_id op tool],
          enums: { "op" => %w[read search write] }
        },
        "shells_out" => {
          identity: %w[tool_use_id],
          body: %w[tool_use_id place_id program command],
          enums: {}
        },
        "reaches" => {
          identity: %w[tool_use_id place_id],
          body: %w[tool_use_id place_id via_program evidence],
          enums: { "evidence" => %w[argument url git_remote] }
        },
        "spawn" => {
          identity: %w[session_key spawn_tool_use_id],
          body: %w[spawn_tool_use_id parent_agent_key child_agent_key spawned_at_place_id requested_type isolation],
          enums: { "isolation" => %w[shared worktree] }
        },
        "lifecycle" => {
          identity: %w[session_key agent_key state source_id],
          body: %w[state source_id],
          enums: { "state" => %w[started running waiting_on_user stopped failed] }
        },
        "message" => {
          identity: %w[session_key agent_key channel message_key],
          body: %w[message_key channel from_agent_key to_agent_key from_address to_address from_name summary head bytes digest source_id
                   delivered_at is_error],
          enums: { "channel" => %w[spawn send handback receive] }
        },
        "context" => {
          identity: %w[session_key agent_key source_id],
          body: %w[source_id model effort standing_place_id branch],
          enums: {}
        },
        "workspace" => {
          identity: %w[place_id sampled_at],
          body: %w[place_id sampled_at status cause branch dirty worktree ahead behind duration_ms],
          enums: { "status" => %w[ok unknown] }
        },
        "usage" => {
          identity: %w[harness request_key counters_digest],
          body: %w[harness request_key counters_digest model service_tier] + COUNTERS + USAGE_PROVIDER_EXTRAS + USAGE_LEDGER +
                USAGE_ATTRIBUTION,
          enums: { "harness" => %w[claude codex] }
        },
        "usage_line" => {
          identity: %w[harness request_key line_uuid line_at],
          body: %w[harness request_key line_uuid line_at],
          enums: { "harness" => %w[claude codex] }
        },
        "usage_detail" => {
          identity: %w[harness request_key],
          body: %w[harness request_key effort cost_usd ttft_ms duration_ms query_source agent_name source],
          enums: { "harness" => %w[claude codex], "source" => %w[otel] }
        },
        "request_start" => {
          identity: %w[harness request_key],
          body: %w[harness request_key started_at],
          enums: { "harness" => %w[claude codex] }
        },
        "tool_call" => {
          identity: %w[session_key tool_use_id],
          body: %w[tool_use_id agent_key tool started_at ended_at duration_ms is_error],
          enums: {}
        },
        "persona" => {
          identity: %w[session_key revision authority effective_at],
          body: %w[revision members lead speaker authority effective_at],
          enums: { "authority" => %w[transcript_observed sampled unknown] }
        },
        "transcript" => {
          identity: %w[session_key agent_key native_inode native_size],
          body: %w[native_inode native_size path sha256 source final],
          enums: { "source" => %w[native bodies specstory_lossy ledger] }
        },
        "task" => {
          identity: %w[id state_digest],
          body: %w[id state_digest name repo started opened_by sessions attached turns subagents fingerprint first_tokens wip_counts last_activity closed merged_into],
          enums: {}
        },
        "gap" => {
          identity: %w[cause location],
          body: %w[cause location harness harness_version detail count],
          enums: { "harness" => %w[claude codex] }
        }
      }.freeze

      NAMES = TABLE.keys.freeze

      module_function

      def fetch(kind)
        TABLE.fetch(kind.to_s) { raise InvalidRecord.new("unknown derived kind #{kind}") }
      end

      def identity_fields(kind)
        fetch(kind)[:identity]
      end
    end
  end
end
