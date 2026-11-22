# frozen_string_literal: true

require "json"
require "uri"
require_relative "../bounds"
require_relative "../record/reader"
require_relative "../record/formats"
require_relative "batch"
require_relative "support"

module Tellem
  module Ingest
    module Codex
      HARNESS = "codex"
      METADATA = %w[world_state inter_agent_communication_metadata compacted].freeze
      TOOL_CALLS = %w[function_call custom_tool_call local_shell_call web_search_call tool_search_call image_generation_call].freeze
      QUIET_ITEMS = %w[compaction compaction_summary ghost_snapshot].freeze
      RENDERED_ROLES = { "user" => "user", "assistant" => "agent" }.freeze
      SKIPPED_ROLES = %w[developer system].freeze
      SPAWN_RESULT_KEYS = %w[agent_id thread_id id].freeze
      NESTED_SHELL = "exec_command"
      SHELL_FLAGS = %w[-c -lc].freeze
      FILE_SCHEME = "file://"
      INJECTED = /\A\s*(?:# AGENTS\.md instructions\b|<environment_context>|<user_instructions>)/

      module_function

      def available?
        true
      end

      def foundation_default?
        false
      end

      def read(path, session_id:, agent_key:, from: nil)
        batch = Batch.new(harness: HARNESS, session_id: session_id, agent_key: agent_key)
        state = { version: nil, model: nil, service_tier: nil, turn_id: nil, prev_total: nil, charged: 0, fallback: [],
                  records: {}, order: [], approval: nil, approvals: {}, session: nil, cwd: nil, turn_cwd: nil, cwds: {} }
        cursor = Record::Reader.each(path, from: from) { |entry| entry(batch, state, entry) }
        batch.usage = state[:order].empty? ? state[:fallback] : state[:order].map { |key| state[:records][key] }
        batch.add_gap("torn_line", detail: { "lines" => cursor["torn"] }, count: cursor["torn"]) if cursor["torn"].positive?
        batch.add_gap("partial_tail", suffix: "offset=#{cursor['offset']}", detail: { "offset" => cursor["offset"] }) if cursor["partial_tail"]
        batch.model = state[:model]
        batch.finish(harness_version: state[:version], cursor: cursor)
      end

      def entry(batch, state, entry)
        ts = Support.rfc3339_ms(entry["timestamp"])
        batch.note_time(ts)
        payload = entry["payload"]
        type = entry["type"]
        return if METADATA.include?(type)
        return shape_gap(batch, type, %w[payload]) if %w[session_meta turn_context event_msg response_item].include?(type) && !payload.is_a?(Hash)

        case type
        when "session_meta" then session_meta(batch, state, payload)
        when "turn_context" then turn_context(state, payload)
        when "event_msg" then event_msg(batch, state, payload, ts)
        when "response_item" then response_item(batch, state, payload, ts)
        when "token_usage_record" then usage_record(batch, state, payload, ts)
        else
          name = Support.safe_token(type)
          batch.add_gap("unrecognized_entry", suffix: "type=#{name}", detail: { "entry_type" => name, "keys" => Support.safe_keys(entry) })
        end
      end

      def usage_record(batch, state, payload, ts)
        return shape_gap(batch, "token_usage_record", %w[payload]) unless payload.is_a?(Hash)

        key = string(payload["response_id"])
        missing = [("response_id" unless key), ("usage" unless payload["usage"].is_a?(Hash))].compact
        return shape_gap(batch, "token_usage_record", missing) unless missing.empty?

        prior = state[:records][key]
        state[:order] << key unless prior
        turn = string(payload["turn_id"])
        entry = request(batch, state, payload["usage"], key, key, ts)
                .merge(ledger(ts, turn || "", state[:approvals].fetch(turn, state[:approval]), key))
                .merge("cwd" => state[:cwds].fetch(turn, state[:turn_cwd] || state[:cwd]))
        entry.merge!(prior.slice("first_line_at", "first_line_uuid")) if prior
        state[:records][key] = entry
      end

      def ledger(ts, uuid, approval, ledger_id)
        {
          "first_line_at" => ts, "first_line_uuid" => uuid, "last_line_at" => ts, "last_line_uuid" => uuid,
          "permission_mode" => approval, "ledger_id" => ledger_id
        }
      end

      def request(batch, state, counts, request_key, provider_id, ts)
        counters(counts).merge(
          "harness" => HARNESS,
          "request_key" => request_key,
          "provider_request_id" => provider_id,
          "session_id" => batch.session_id,
          "agent_key" => batch.agent_key,
          "model" => state[:model],
          "service_tier" => state[:service_tier],
          "ts" => ts
        )
      end

      def shape_gap(batch, type, missing)
        name = Support.safe_token(type)
        batch.add_gap("unrecognized_shape", suffix: "type=#{name}", detail: { "entry_type" => name, "missing_keys" => missing })
      end

      def session_meta(batch, state, payload)
        state[:version] = payload["cli_version"] if payload["cli_version"].is_a?(String)
        state[:session] = string(payload["session_id"]) || string(payload["id"]) || state[:session]
        state[:cwd] = string(payload["cwd"]) || state[:cwd]
        batch.thread_id = string(payload["id"]) || string(payload["session_id"])
        spawn = payload.dig("source", "subagent", "thread_spawn") if payload["source"].is_a?(Hash)
        spawn = nil unless spawn.is_a?(Hash)
        batch.parent_thread_id = string(payload["parent_thread_id"]) || (spawn && string(spawn["parent_thread_id"]))
        other = payload.dig("source", "subagent", "other") if payload["source"].is_a?(Hash) && payload["source"]["subagent"].is_a?(Hash)
        batch.agent_role = string(payload["agent_role"]) || (spawn && string(spawn["agent_role"])) || string(other)
        batch.note_time(Support.rfc3339_ms(payload["timestamp"]))
      end

      def turn_context(state, payload)
        state[:model] = payload["model"] if payload["model"].is_a?(String)
        state[:turn_id] = payload["turn_id"] if payload["turn_id"].is_a?(String)
        state[:approval] = string(payload["approval_policy"])
        state[:approvals][state[:turn_id]] = state[:approval] if state[:turn_id]
        state[:turn_cwd] = string(payload["cwd"]) || state[:cwd]
        state[:cwds][state[:turn_id]] = state[:turn_cwd] if state[:turn_id]
      end

      def event_msg(batch, state, payload, ts)
        case payload["type"]
        when "token_count" then token_count(batch, state, payload, ts)
        when "item_completed"
          subagent_activity(batch, payload["item"])
          command_execution(batch, state, payload["item"], ts)
        when "thread_settings_applied"
          tier = payload.dig("thread_settings", "service_tier") if payload["thread_settings"].is_a?(Hash)
          state[:service_tier] = tier if tier.is_a?(String)
        end
      end

      def token_count(batch, state, payload, ts)
        info = payload["info"]
        return unless info.is_a?(Hash) && info["total_token_usage"].is_a?(Hash)

        total = info["total_token_usage"]
        return if total == state[:prev_total]

        state[:prev_total] = total
        last = info["last_token_usage"]
        unless last.is_a?(Hash)
          batch.add_gap("usage_without_last_token_usage", detail: { "events" => 1 })
          return
        end

        state[:charged] += 1
        ledger_id = "codex:#{state[:session] || batch.session_id}:#{total['total_tokens']}"
        state[:fallback] << request(batch, state, last, "#{batch.thread_id || batch.session_id}:#{state[:charged]}", nil, ts)
                            .merge(ledger(ts, state[:turn_id] || "", state[:approval], ledger_id))
                            .merge("cwd" => state[:turn_cwd] || state[:cwd])
      end

      def subagent_activity(batch, item)
        return unless item.is_a?(Hash) && item["type"] == "SubAgentActivity"

        call = string(item["id"])
        child = string(item["agent_thread_id"])
        batch.link_subagent(call, child) if call && child
      end

      def command_execution(batch, state, item, ts)
        return unless item.is_a?(Hash) && item["type"] == "CommandExecution"

        id = string(item["id"])
        command = executed_command(item["command"])
        return if id.nil? || command.nil? || batch.tool?(id)

        batch.add_tool(id: id, name: NESTED_SHELL, input: { "cmd" => command }, ts: ts, model: state[:model],
                       cwd: local_path(item["cwd"]))
        code = item["exit_code"]
        failed = code.is_a?(Integer) && !code.zero?
        batch.add_result(id, Support.block_text(item["aggregated_output"]), ts: ts, is_error: failed ? true : nil)
      end

      def executed_command(command)
        return command if command.is_a?(String) && !command.empty?
        return nil unless command.is_a?(Array) && !command.empty? && command.all?(String)
        return command[2] if command.size == 3 && SHELL_FLAGS.include?(command[1])

        command.join(" ")
      end

      def local_path(value)
        return nil unless value.is_a?(String) && !value.empty?
        return value unless value.start_with?(FILE_SCHEME)

        path = URI.decode_www_form_component(value.delete_prefix(FILE_SCHEME).gsub("+", "%2B"))
        path.start_with?("/") ? path : nil
      end

      def counters(last)
        out = Record::Kinds::COUNTERS.to_h { |key| [key, nil] }
        Record::Formats::CODEX_COUNTER_MAP.each { |field, key| out[field] = Support.integer(last[key]) }
        out
      end

      def response_item(batch, state, payload, ts)
        type = payload["type"].to_s
        if type == "message" then message(batch, state, payload, ts)
        elsif type == "reasoning" then reasoning(batch, state, payload, ts)
        elsif type == "agent_message"
          agent_message(batch, payload, ts)
        elsif TOOL_CALLS.include?(type) then tool_call(batch, state, payload, type, ts)
        elsif type.end_with?("_call_output") then tool_output(batch, payload, ts)
        elsif !QUIET_ITEMS.include?(type)
          name = Support.safe_token(type)
          batch.add_gap("unrecognized_item", suffix: "type=#{name}", detail: { "item_type" => name, "keys" => Support.safe_keys(payload) })
        end
      end

      def agent_message(batch, payload, ts)
        text = Support.block_text(payload["content"])
        unless text.nil? || text.strip.empty?
          ref = string(payload["id"]) || "agent_message:#{batch.received.size}"
          batch.note_received(ts, ref, { "tag" => "agent_message", "text" => text })
        end
        batch.add_text("user", ts, text, source: "agent_message")
      end

      def reasoning(batch, state, payload, ts)
        batch.count_reasoning(state[:turn_id] || payload["id"])
        parts = Array(payload["summary"]) + Array(payload["content"])
        texts = parts.filter_map { |part| part["text"] if part.is_a?(Hash) && part["text"].is_a?(String) && !part["text"].empty? }
        batch.add_reasoning(ts, texts.join("\n\n"))
      end

      def message(batch, state, payload, ts)
        role = payload["role"].to_s
        return if SKIPPED_ROLES.include?(role)

        rendered = RENDERED_ROLES[role]
        unless rendered
          batch.add_gap("unrecognized_role", suffix: "role=#{Support.safe_token(role)}", detail: { "role" => Support.safe_token(role) })
          return
        end

        batch.add_text(rendered, ts, Support.block_text(payload["content"]), model: state[:model], titled: !injected?(payload["content"]))
      end

      def injected?(content)
        texts = Array(content).filter_map { |part| part["text"] if part.is_a?(Hash) && part["text"].is_a?(String) }
        texts = [content] if content.is_a?(String)
        !texts.empty? && texts.all? { |text| INJECTED.match?(text) }
      end

      def tool_call(batch, state, payload, type, ts)
        id = string(payload["call_id"]) || string(payload["id"])
        name = string(payload["name"]) || type.delete_suffix("_call")
        batch.add_tool(id: id, name: name, input: call_input(payload), ts: ts, model: state[:model])
      end

      def call_input(payload)
        if payload["arguments"].is_a?(String)
          parse(payload["arguments"]) || payload["arguments"]
        else
          payload["arguments"] || payload["input"] || payload["action"]
        end
      end

      def tool_output(batch, payload, ts)
        id = string(payload["call_id"])
        output = payload["output"]
        output = output["content"] if output.is_a?(Hash) && output.key?("content")
        text = Support.block_text(output)
        failed = payload["output"].is_a?(Hash) && payload["output"]["success"] == false
        batch.add_result(id, text, ts: ts, is_error: failed ? true : nil)
        batch.link_subagent(id, spawned_id(text)) if id && spawn_call?(batch, id)
      end

      def spawn_call?(batch, id)
        call = batch.tool_calls.find { |entry| entry["id"] == id }
        call && call["name"] == "spawn_agent"
      end

      def spawned_id(text)
        data = text.is_a?(String) ? parse(text) : nil
        return nil unless data.is_a?(Hash)

        SPAWN_RESULT_KEYS.each { |key| return data[key] if data[key].is_a?(String) }
        nil
      end

      def parse(text)
        Bounds.parse_json(text)
      rescue Tellem::Error
        nil
      end

      def string(value)
        value.is_a?(String) && !value.empty? ? value : nil
      end
    end
  end
end
