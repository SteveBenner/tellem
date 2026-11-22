# frozen_string_literal: true

require_relative "billing"
require_relative "command"

module Tellem
  module Hook
    module Extract
      HARNESS_EVENTS = {
        "session_start" => %w[SessionStart],
        "prompt_submit" => %w[UserPromptSubmit],
        "post_tool" => %w[PostToolUse PostToolUseFailure],
        "stop" => %w[Stop],
        "session_end" => %w[SessionEnd],
        "subagent_start" => %w[SubagentStart],
        "subagent_stop" => %w[SubagentStop]
      }.freeze
      FAILURE_EVENTS = %w[PostToolUseFailure].freeze
      COMMON_KEYS = %w[session_id hook_event_name cwd transcript_path].freeze
      EVENT_KEYS = {
        "session_start" => %w[source],
        "post_tool" => %w[tool_name tool_input tool_use_id],
        "subagent_start" => %w[agent_id agent_type],
        "subagent_stop" => %w[agent_id agent_type agent_transcript_path]
      }.freeze
      OBJECT_KEYS = %w[tool_input].freeze
      SHELL_TOOLS = {
        "claude" => %w[Bash].freeze,
        "codex" => %w[Bash shell exec_command].freeze
      }.freeze
      COMMAND_KEYS = %w[command cmd].freeze
      PATH_KEYS = %w[file_path path notebook_path].freeze
      URL_KEY = "url"
      STRING_BYTES = 4096

      module_function

      def fields(payload, harness:, event:)
        input = payload["tool_input"].is_a?(Hash) ? payload["tool_input"] : {}
        tool = string(payload["tool_name"])
        missing = missing_keys(payload, event)
        {
          "harness" => harness,
          "harness_event" => string(payload["hook_event_name"]) || "",
          "event" => event,
          "session_id" => string(payload["session_id"]),
          "agent_id" => string(payload["agent_id"]),
          "agent_type" => string(payload["agent_type"]),
          "cwd" => string(payload["cwd"]),
          "tool" => tool,
          "tool_use_id" => string(payload["tool_use_id"]),
          "paths" => event == "post_tool" ? paths(input) : nil,
          "program" => event == "post_tool" && shell_tool?(harness, tool) ? program(input) : nil,
          "url_host" => event == "post_tool" ? Command.url_host(input[URL_KEY]) : nil,
          "transcript_path" => string(payload["transcript_path"]),
          "agent_transcript_path" => event == "subagent_stop" ? string(payload["agent_transcript_path"]) : nil,
          "start_source" => event == "session_start" ? string(payload["source"]) : nil,
          "permission_mode" => string(payload["permission_mode"]),
          "billing" => event == "session_start" ? Billing.detect(harness) : nil,
          "outcome" => event == "post_tool" ? outcome(payload) : nil,
          "shape" => missing.empty? ? "known" : "unrecognized",
          "missing_keys" => missing
        }
      end

      def missing_keys(payload, event)
        required = COMMON_KEYS + EVENT_KEYS.fetch(event, [])
        missing = required.reject { |key| present?(payload, key) }
        name = payload["hook_event_name"]
        missing << "hook_event_name" if name.is_a?(String) && !HARNESS_EVENTS.fetch(event, []).include?(name)
        missing.uniq
      end

      def present?(payload, key)
        value = payload[key]
        OBJECT_KEYS.include?(key) ? value.is_a?(Hash) : value.is_a?(String)
      end

      def string(value)
        value.is_a?(String) && value.bytesize <= STRING_BYTES ? value : nil
      end

      def shell_tool?(harness, tool)
        SHELL_TOOLS.fetch(harness, []).include?(tool)
      end

      def program(input)
        key = COMMAND_KEYS.find { |name| input[name].is_a?(String) || input[name].is_a?(Array) }
        key ? Command.program(input[key]) : nil
      end

      def paths(input)
        found = PATH_KEYS.map { |key| input[key] }.grep(String)
        found.empty? ? nil : found
      end

      def outcome(payload)
        return "error" if FAILURE_EVENTS.include?(payload["hook_event_name"])

        response = payload["tool_response"]
        return nil if response.nil?
        return "error" if response.is_a?(Hash) && (response["is_error"] == true || response["success"] == false)

        "ok"
      end
    end
  end
end
