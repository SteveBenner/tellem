# frozen_string_literal: true

require_relative "support"

module Tellem
  module Ingest
    class Batch
      FIELDS = %i[
        harness session_id agent_key agent_id thread_id parent_thread_id agent_role harness_version model started_at
        title exchanges usage tool_calls persona_results subagents reasoning gaps cursor
      ].freeze

      PATH_KEYS = %w[file_path path notebook_path].freeze

      attr_accessor(*FIELDS)
      attr_accessor :entries, :entry_origin, :received
      attr_reader :input_bytes, :result_bytes, :async_results

      def initialize(harness:, session_id:, agent_key:)
        @harness = harness
        @session_id = session_id
        @agent_key = agent_key
        @exchanges = []
        @usage = []
        @tool_calls = []
        @persona_results = []
        @subagents = []
        @reasoning = { "blocks" => 0, "by_request" => {} }
        @gaps = []
        @gap_index = {}
        @tools = {}
        @entries = []
        @entry_origin = "native"
        @received = []
        @input_bytes = {}
        @result_bytes = {}
        @async_results = {}
      end

      def session_key
        "#{harness}-#{session_id}"
      end

      def location(suffix = nil)
        base = "transcript/#{session_key}/#{agent_key}"
        suffix ? "#{base}:#{suffix}" : base
      end

      def note_time(ts)
        return unless ts

        @started_at = ts if @started_at.nil? || ts < @started_at
      end

      def add_gap(cause, suffix: nil, detail: {}, count: 1)
        loc = location(suffix)
        key = [cause, loc]
        if (existing = @gap_index[key])
          existing["count"] += count
          return existing
        end

        entry = Support.gap(cause: cause, location: loc, harness: harness, harness_version: nil, detail: detail, count: count)
        @gap_index[key] = entry
        @gaps << entry
        entry
      end

      def count_reasoning(request, blocks = 1)
        @reasoning["blocks"] += blocks
        key = request.to_s
        @reasoning["by_request"][key] = @reasoning["by_request"].fetch(key, 0) + blocks
      end

      def add_text(role, ts, text, model: nil, request_key: nil, source: nil, titled: true, ref: nil)
        return if text.nil? || text.strip.empty?

        @title ||= Support.title(text) if role == "user" && titled && (source.nil? || source == "queued")
        exchange = { "role" => role, "ts" => ts, "kind" => "text", "text" => Redact.text(text) }
        exchange["model"] = model if role == "agent"
        exchange["request_key"] = request_key if request_key
        exchange["source"] = source if source
        @exchanges << exchange
        note_entry(role == "user" ? "prompt" : "reply", ts, text, ref: ref, note: source)
        exchange
      end

      def add_reasoning(ts, text, ref: nil)
        return unless text.is_a?(String) && !text.strip.empty?

        note_entry("reasoning", ts, text, ref: ref)
      end

      def add_tool(id:, name:, input:, ts:, model: nil, request_key: nil, cwd: nil, ref: nil)
        redacted = Support.redact_input(input)
        tool = { "id" => id, "name" => name, "type" => Support.tool_type(name), "input" => redacted,
                 "result" => nil, "is_error" => nil }
        tool["cwd"] = cwd if cwd.is_a?(String) && !cwd.empty?
        exchange = { "role" => "agent", "ts" => ts, "kind" => "tool", "model" => model, "tool" => tool }
        exchange["request_key"] = request_key if request_key
        @exchanges << exchange
        @tool_calls << { "id" => id, "name" => name, "input" => redacted, "timestamp" => ts, "is_error" => nil }
        @tools[id] = { tool: tool, call: @tool_calls.last, persona: Support.persona_call?(name, input) } if id
        @input_bytes[id] = Support.message_sizes(input) if id && tool["type"] == "agent"
        note_entry("action", ts, input, ref: ref || (id && "call:#{id}"), tool: name, call_id: id,
                                        paths: input_paths(input), cwd: cwd.is_a?(String) ? cwd : nil)
        exchange
      end

      def tool?(id)
        @tools.key?(id)
      end

      def add_result(id, text, ts:, is_error: nil, extra: nil, ref: nil, async: false)
        entry = @tools[id]
        unless entry
          add_gap("unmatched_tool_result", detail: { "tool_use_ids" => 1 })
          return nil
        end

        tool = entry[:tool]
        @async_results[id] = true if async && tool["type"] == "agent"
        @result_bytes[id] = text.bytesize if text.is_a?(String) && tool["type"] == "agent"
        tool["result"] = Support.redact_result(text)
        tool["is_error"] = is_error
        tool["result_at"] = ts
        tool.merge!(extra) if extra
        entry[:call]["is_error"] = is_error
        note_entry("output", ts, text.to_s, ref: ref, tool: tool["name"], call_id: id, note: is_error ? "error" : nil)
        @persona_results << { "tool_use_id" => id, "at" => ts, "text" => Redact.text(text.to_s) } if entry[:persona] && text
        tool
      end

      def note_received(ts, ref, parsed)
        return unless ts.is_a?(String) && parsed.is_a?(Hash) && parsed["text"].is_a?(String)

        @received << parsed.slice("tag", "from", "from_name", "from_mode", "text").merge("ts" => ts, "ref" => ref)
      end

      def link_subagent(tool_use_id, agent_id)
        entry = @tools[tool_use_id]
        return unless entry && agent_id.is_a?(String) && !agent_id.empty?

        entry[:tool]["subagent_id"] = agent_id
        @subagents << { "tool_use_id" => tool_use_id, "agent_id" => agent_id } unless @subagents.any? { |s| s["tool_use_id"] == tool_use_id }
      end

      def finish(harness_version:, cursor:)
        @harness_version = harness_version
        @cursor = cursor
        @gaps.each { |entry| entry["harness_version"] = harness_version }
        self
      end

      def note_entry(kind, ts, content, ref: nil, tool: nil, call_id: nil, note: nil, paths: nil, cwd: nil)
        entry = { "kind" => kind, "at" => ts, "tool" => tool, "call_id" => call_id, "content" => content,
                  "ref" => ref || "n#{@entries.size}", "note" => note }
        entry["paths"] = paths if paths
        entry["cwd"] = cwd if cwd
        @entries << entry
        entry
      end

      def input_paths(input)
        return [] unless input.is_a?(Hash)

        PATH_KEYS.map { |key| input[key] }.grep(String).reject(&:empty?)
      end

      def to_h
        FIELDS.to_h { |field| [field.to_s, public_send(field)] }
      end
    end
  end
end
