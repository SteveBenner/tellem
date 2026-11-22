# frozen_string_literal: true

require_relative "../ids"
require_relative "../record/reader"
require_relative "../record/formats"
require_relative "batch"
require_relative "support"

module Tellem
  module Ingest
    module Claude
      HARNESS = "claude"
      CONVERSATION = %w[user assistant].freeze
      METADATA = %w[
        system attachment summary ai-title custom-title api-request api-request-blob api-request-shape atis-latch
        file-history-delta file-history-snapshot last-prompt mode permission-mode queue-operation tag agent-name
        agent-color pr-link worktree-state session-owner tools-used cost-state
      ].freeze
      REQUIRED = %w[type timestamp message].freeze
      ASSISTANT_BLOCKS = %w[text tool_use thinking redacted_thinking server_tool_use web_search_tool_result].freeze
      SERVER_RESULT_SUFFIX = "_tool_result"
      ENDING_TOOLS = %w[SubagentHandback].freeze
      USER_BLOCKS = %w[text tool_result image document].freeze
      THINKING = %w[thinking redacted_thinking].freeze
      SYNTHETIC_MODEL = "<synthetic>"
      AGENT_ID_IN_TEXT = /\bagentId:\s*([A-Za-z0-9_-]{1,128})/

      module_function

      def available?
        true
      end

      def foundation_default?
        false
      end

      def read(path, session_id:, agent_key:, from: nil)
        batch = Batch.new(harness: HARNESS, session_id: session_id, agent_key: agent_key)
        state = { requests: {}, order: [], version: nil, model: nil, queued: 0 }
        cursor = Record::Reader.each(path, from: from) { |entry| entry(batch, state, entry) }
        batch.add_gap("torn_line", detail: { "lines" => cursor["torn"] }, count: cursor["torn"]) if cursor["torn"].positive?
        batch.add_gap("partial_tail", suffix: "offset=#{cursor['offset']}", detail: { "offset" => cursor["offset"] }) if cursor["partial_tail"]
        batch.usage = state[:order].map { |key| state[:requests][key] }
        batch.model = state[:model]
        batch.finish(harness_version: state[:version], cursor: cursor)
      end

      def entry(batch, state, entry)
        type = entry["type"]
        state[:version] = entry["version"] if entry["version"].is_a?(String)
        batch.agent_id ||= entry["agentId"] if entry["agentId"].is_a?(String)
        ts = Support.rfc3339_ms(entry["timestamp"])
        batch.note_time(ts)
        return conversation(batch, state, entry, ts) if CONVERSATION.include?(type)
        return queued(batch, entry["attachment"], ts, entry["uuid"]) if type == "attachment"

        enqueued(batch, state, entry, ts) if type == "queue-operation"
        return if METADATA.include?(type)

        name = Support.safe_token(type)
        batch.add_gap("unrecognized_entry", suffix: "type=#{name}", detail: { "entry_type" => name, "keys" => Support.safe_keys(entry) })
      end

      def enqueued(batch, state, entry, ts)
        return unless entry["operation"] == "enqueue"

        state[:queued] += 1
        batch.note_received(ts, "queue:#{ts}:#{state[:queued]}", Support.received_tag(entry["content"]))
      end

      def queued(batch, attachment, ts, uuid)
        return unless attachment.is_a?(Hash) && attachment["type"] == "queued_command"

        batch.note_received(ts, line_ref(uuid, "queued") || "queued:#{ts}", Support.received_tag(Support.block_text(attachment["prompt"])))
        return unless attachment["commandMode"] == "prompt"
        return unless attachment["origin"].is_a?(Hash) && attachment["origin"]["kind"] == "human"

        batch.add_text("user", ts, Support.block_text(attachment["prompt"]), source: "queued", ref: line_ref(uuid, "queued"))
      end

      def conversation(batch, state, entry, ts)
        missing = REQUIRED.reject { |key| entry.key?(key) }
        missing << "timestamp" if ts.nil? && !missing.include?("timestamp")
        message = entry["message"]
        missing << "message" unless message.is_a?(Hash) || missing.include?("message")
        missing << "message.content" if message.is_a?(Hash) && !message.key?("content")
        unless missing.empty?
          batch.add_gap("unrecognized_shape", suffix: "type=#{entry['type']}",
                                              detail: { "entry_type" => entry["type"], "missing_keys" => missing.uniq.sort })
          return
        end

        entry["type"] == "assistant" ? assistant(batch, state, entry, message, ts) : user(batch, entry, message, ts)
      end

      def line_ref(uuid, part)
        uuid.is_a?(String) && !uuid.empty? ? "#{uuid}:#{part}" : nil
      end

      def assistant(batch, state, entry, message, ts)
        model = message["model"].is_a?(String) ? message["model"] : nil
        request_key = message["id"].is_a?(String) ? message["id"] : nil
        state[:model] = model if model && model != SYNTHETIC_MODEL
        usage(batch, state, entry, message, ts, model, request_key)
        stop_reason = message["stop_reason"].is_a?(String) ? message["stop_reason"] : nil
        blocks(message["content"]).each_with_index do |block, index|
          exchange = assistant_block(batch, entry, block, ts, model, request_key, line_ref(entry["uuid"], index))
          exchange["stop_reason"] = stop_reason if exchange.is_a?(Hash) && exchange["role"] == "agent"
        end
      end

      def assistant_block(batch, entry, block, ts, model, request_key, ref)
        type = block["type"].to_s
        return server_result(batch, block, ts, ref) if type.end_with?(SERVER_RESULT_SUFFIX) && block["tool_use_id"].is_a?(String)

        case type
        when "text" then batch.add_text("agent", ts, block["text"], model: model, request_key: request_key, ref: ref)
        when "tool_use", "server_tool_use"
          exchange = batch.add_tool(id: block["id"], name: block["name"].to_s, input: block["input"], ts: ts, model: model,
                                    request_key: request_key, cwd: entry["cwd"], ref: ref)
          exchange["tool"]["server"] = true if type == "server_tool_use"
          exchange["tool"]["ends_agent"] = true if ENDING_TOOLS.include?(block["name"])
          exchange
        when *THINKING
          batch.count_reasoning(request_key || entry["uuid"])
          batch.add_reasoning(ts, block["thinking"], ref: ref)
          batch.note_entry("reasoning", ts, "", ref: ref, note: block["unavailable"]) if block["unavailable"].is_a?(String)
        when *ASSISTANT_BLOCKS then nil
        else unknown_block(batch, "assistant", block)
        end
      end

      def server_result(batch, block, ts, ref)
        content = block["content"]
        error = content.is_a?(Hash) && content["type"].to_s.end_with?("_error")
        batch.add_result(block["tool_use_id"], server_text(content), ts: ts, is_error: error, ref: ref)
        nil
      end

      def server_text(content)
        case content
        when Array then content.filter_map { |part| server_part(part) }.join("\n")
        when Hash then server_part(content)
        else Support.block_text(content)
        end
      end

      def server_part(part)
        return part if part.is_a?(String)
        return nil unless part.is_a?(Hash)
        return part["text"] if part["text"].is_a?(String)
        return "error: #{part['error_code']}" if part["type"].to_s.end_with?("_error")

        line = [part["title"], part["url"]].grep(String).join(" - ")
        line.empty? ? nil : line
      end

      def user(batch, entry, message, ts)
        source = user_source(entry)
        texts = []
        blocks(message["content"]).each_with_index do |block, index|
          case block["type"]
          when "text" then texts << block["text"]
          when "image", "document" then texts << "[#{block['type']} omitted]"
          when "tool_result" then result(batch, entry, block, ts, line_ref(entry["uuid"], index))
          else unknown_block(batch, "user", block)
          end
        end
        text = texts.compact.join("\n\n")
        batch.note_received(ts, line_ref(entry["uuid"], "text") || "user:#{ts}", Support.received_tag(text))
        batch.add_text("user", ts, text, source: source, ref: line_ref(entry["uuid"], "text"))
      end

      def user_source(entry)
        return "compact_summary" if entry["isCompactSummary"] == true
        return "meta" if entry["isMeta"] == true

        nil
      end

      def result(batch, entry, block, ts, ref)
        id = block["tool_use_id"]
        text = Support.block_text(block["content"])
        extra = answers(entry["toolUseResult"])
        batch.add_result(id, text, ts: ts, is_error: block["is_error"] == true, extra: extra, ref: ref, async: async_launch?(entry["toolUseResult"]))
        batch.link_subagent(id, subagent_id(entry["toolUseResult"], text))
      end

      def async_launch?(tool_result)
        tool_result.is_a?(Hash) && (tool_result["status"] == "async_launched" || tool_result["isAsync"] == true)
      end

      def answers(tool_result)
        return nil unless tool_result.is_a?(Hash) && tool_result["answers"].is_a?(Hash)

        { "answers" => Support.deep(tool_result["answers"]) }
      end

      def subagent_id(tool_result, text)
        return tool_result["agentId"] if tool_result.is_a?(Hash) && tool_result["agentId"].is_a?(String)

        text.is_a?(String) ? text[AGENT_ID_IN_TEXT, 1] : nil
      end

      def blocks(content)
        return [{ "type" => "text", "text" => content }] if content.is_a?(String)

        Array(content).select { |block| block.is_a?(Hash) }
      end

      def unknown_block(batch, role, block)
        name = Support.safe_token(block["type"])
        batch.add_gap("unrecognized_block", suffix: "#{role}:type=#{name}", detail: { "role" => role, "block_type" => name, "keys" => Support.safe_keys(block) })
      end

      def usage(batch, state, entry, message, ts, model, request_key)
        raw = message["usage"]
        return unless raw.is_a?(Hash)
        return if model == SYNTHETIC_MODEL

        unless request_key
          batch.add_gap("usage_without_request_id", detail: { "entries" => 1 })
          return
        end

        first = state[:requests][request_key]
        state[:order] << request_key unless first
        state[:requests][request_key] = counters(raw).merge(extras(raw, message)).merge(lines(entry, ts, first)).merge(
          "harness" => HARNESS,
          "request_key" => request_key,
          "provider_request_id" => entry["requestId"].is_a?(String) ? entry["requestId"] : nil,
          "session_id" => batch.session_id,
          "agent_key" => batch.agent_key,
          "model" => model,
          "service_tier" => raw["service_tier"].is_a?(String) ? raw["service_tier"] : nil,
          "cwd" => (first && first["cwd"]) || line_cwd(entry),
          "ts" => ts
        )
      end

      def line_cwd(entry)
        cwd = entry["cwd"]
        cwd.is_a?(String) && cwd.start_with?("/") ? cwd : nil
      end

      def counters(raw)
        parts = Record::Formats::CLAUDE_TOTAL_PARTS.to_h { |key| [key, Support.integer(raw[key])] }
        total = parts.values.all? ? parts.values.sum : nil
        parts.merge("reasoning_tokens" => nil, "total_tokens" => total)
      end

      def lines(entry, ts, first)
        uuid = entry["uuid"].is_a?(String) ? entry["uuid"] : nil
        {
          "first_line_at" => first ? first["first_line_at"] : ts,
          "first_line_uuid" => first ? first["first_line_uuid"] : uuid,
          "last_line_at" => ts,
          "last_line_uuid" => uuid
        }
      end

      def extras(raw, message)
        cache = raw["cache_creation"].is_a?(Hash) ? raw["cache_creation"] : {}
        server = raw["server_tool_use"].is_a?(Hash) ? raw["server_tool_use"] : {}
        {
          "inference_geo" => raw["inference_geo"].is_a?(String) ? raw["inference_geo"] : nil,
          "speed" => raw["speed"].is_a?(String) ? raw["speed"] : nil,
          "stop_reason" => message["stop_reason"].is_a?(String) ? message["stop_reason"] : nil,
          "cache_creation_ephemeral_1h_input_tokens" => Support.integer(cache["ephemeral_1h_input_tokens"]),
          "cache_creation_ephemeral_5m_input_tokens" => Support.integer(cache["ephemeral_5m_input_tokens"]),
          "server_tool_use_web_search_requests" => Support.integer(server["web_search_requests"]),
          "server_tool_use_web_fetch_requests" => Support.integer(server["web_fetch_requests"])
        }
      end
    end
  end
end
