# frozen_string_literal: true

require "json"
require "time"
require_relative "../bounds"
require_relative "../redact"
require_relative "../seams"

module Tellem
  module Ingest
    module Support
      TOOL_TYPES = {
        "shell" => %w[Bash bash shell local_shell exec_command exec write_stdin BashOutput KillShell],
        "read" => %w[Read NotebookRead read_file view_image],
        "write" => %w[Write Edit MultiEdit NotebookEdit apply_patch],
        "search" => %w[Grep Glob LS ToolSearch tool_search grep_files list_dir],
        "web" => %w[WebFetch WebSearch web_search web_fetch],
        "agent" => %w[Task Agent SendMessage SubagentHandback spawn_agent send_input send_message wait wait_agent close_agent resume_agent]
      }.freeze
      TOOL_TYPE_BY_NAME = TOOL_TYPES.flat_map { |type, names| names.map { |name| [name, type] } }.to_h.freeze
      SHELL_INPUT_KEYS = %w[command cmd].freeze
      URL_KEYS = %w[url uri].freeze
      SAFE_TOKEN = /[^A-Za-z0-9_.:-]/
      SLUG_WORDS = 4
      TITLE_BYTES = 200
      MESSAGE_KEYS = %w[prompt message description items].freeze
      RECEIVED_TAG = /\A<(cross-session-message|agent-message|teammate-message)((?:\s+[\w-]+="[^"]*")*)\s*>\n?(.*?)(?:\n?<\/\1>\s*)?\z/m.freeze
      TAG_ATTRIBUTE = /([\w-]+)="([^"]*)"/.freeze

      module_function

      def message_field(key, value)
        text = key == "items" && value.is_a?(Array) ? block_text(value) : value
        text.is_a?(String) && !text.empty? ? text : nil
      end

      def message_sizes(input)
        return {} unless input.is_a?(Hash)

        MESSAGE_KEYS.each_with_object({}) do |key, out|
          text = message_field(key, input[key])
          out[key] = text.bytesize if text
        end
      end

      def received_tag(text)
        return nil unless text.is_a?(String)

        match = RECEIVED_TAG.match(text)
        return nil unless match

        attributes = match[2].scan(TAG_ATTRIBUTE).to_h
        { "tag" => match[1], "from" => attributes["from"], "from_name" => attributes["from-name"],
          "from_mode" => attributes["from-mode"], "text" => match[3] }
      end

      def rfc3339_ms(value)
        return nil unless value.is_a?(String) && !value.empty?

        Time.iso8601(value).utc.strftime("%Y-%m-%dT%H:%M:%S.%LZ")
      rescue ArgumentError
        nil
      end

      def tool_type(name)
        TOOL_TYPE_BY_NAME.fetch(name.to_s, "other")
      end

      def payload_bytes(value)
        case value
        when nil then 0
        when String then value.bytesize
        else JSON.generate(value).bytesize
        end
      rescue JSON::GeneratorError, EncodingError
        0
      end

      def omitted(bytes)
        { "content_omitted" => bytes }
      end

      def over?(bytes)
        bytes > Bounds::TOOL_PAYLOAD_BYTES
      end

      def redact_input(value)
        bytes = payload_bytes(value)
        return omitted(bytes) if over?(bytes)

        deep(value)
      end

      def redact_result(text)
        return nil if text.nil?

        bytes = text.bytesize
        return omitted(bytes) if over?(bytes)

        Redact.text(text)
      end

      def deep(value, key = nil)
        case value
        when Hash then value.each_with_object({}) { |(k, v), out| out[k.to_s] = deep(v, k.to_s) }
        when Array then value.map { |item| deep(item, key) }
        when String then redact_string(value, key)
        else value
        end
      end

      def redact_string(value, key)
        return Redact.marker(:assignment) if key && Redact.secret_name?(key) && !value.empty?
        return Redact.url(value) if key && URL_KEYS.include?(key)

        Redact.text(value)
      end

      def block_text(content)
        case content
        when String then content
        when Array
          parts = content.filter_map do |part|
            next part if part.is_a?(String)
            next unless part.is_a?(Hash)

            if part["text"].is_a?(String) then part["text"]
            elsif %w[image input_image].include?(part["type"]) then "[image omitted]"
            elsif part["type"].to_s.include?("encrypted") then "[encrypted content omitted]"
            end
          end
          parts.join("\n")
        when nil then nil
        else JSON.generate(content)
        end
      end

      def code_mode_call?(name, input)
        name.to_s == "exec" && input.is_a?(String)
      end

      def shell_command(name, input)
        return nil if code_mode_call?(name, input)
        return nil unless input.is_a?(Hash)

        SHELL_INPUT_KEYS.each do |key|
          value = input[key]
          return value if value.is_a?(String)
          return value.join(" ") if value.is_a?(Array) && value.all?(String)
        end
        nil
      end

      def persona_call?(name, input)
        command = shell_command(name, input)
        command.is_a?(String) && transition_command?(command)
      end

      def transition_command?(command)
        identity = Seams.fetch(:identity)
        identity.respond_to?(:transition_command?) && identity.transition_command?(command) == true
      rescue StandardError
        false
      end

      def safe_token(value, max = 64)
        value.to_s.gsub(SAFE_TOKEN, "")[0, max]
      end

      def safe_keys(hash)
        return [] unless hash.is_a?(Hash)

        hash.keys.map { |key| safe_token(key) }.reject(&:empty?).uniq.sort.first(64)
      end

      def gap(cause:, location:, harness:, harness_version:, detail: {}, count: 1)
        {
          "cause" => cause,
          "location" => location,
          "harness" => harness,
          "harness_version" => harness_version,
          "detail" => detail,
          "count" => count
        }
      end

      def title(text)
        return nil unless text.is_a?(String)

        line = Redact.text(text).strip
        line.empty? ? nil : line.byteslice(0, TITLE_BYTES).scrub("")
      end

      def slug(title)
        title.to_s.downcase.scan(/[a-z0-9]+/).first(SLUG_WORDS).join("-")
      end

      def integer(value)
        value.is_a?(Integer) ? value : nil
      end
    end
  end
end
