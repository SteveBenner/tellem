# frozen_string_literal: true

require_relative "../ids"

module Tellem
  module Otel
    module Extract
      EVENT_NAME = "api_request"
      EVENT_BODY = "claude_code.api_request"
      STRINGS = {
        "session.id" => "session_id", "request_id" => "request_id", "model" => "model", "effort" => "effort",
        "query_source" => "query_source", "agent.name" => "agent_name"
      }.freeze
      INTEGERS = {
        "ttft_ms" => "ttft_ms", "duration_ms" => "duration_ms", "input_tokens" => "input_tokens", "output_tokens" => "output_tokens",
        "cache_read_tokens" => "cache_read_tokens", "cache_creation_tokens" => "cache_creation_tokens"
      }.freeze
      FIELDS = %w[ts session_id request_id model effort cost_usd ttft_ms duration_ms query_source agent_name
                  input_tokens output_tokens cache_read_tokens cache_creation_tokens].freeze
      STRING_BYTES = 200
      TIMESTAMP = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z\z/
      REQUEST_ID = /\A[A-Za-z0-9_-]{1,200}\z/

      module_function

      def events(document)
        kept = []
        refused = Hash.new(0)
        ignored = 0
        each_record(document) do |record|
          attributes = attributes(record["attributes"])
          unless api_request?(record, attributes)
            ignored += 1
            next
          end

          event, cause = event(record, attributes)
          event ? kept << event : refused[cause] += 1
        end
        [kept, refused, ignored]
      end

      def each_record(document)
        return unless document.is_a?(Hash)

        Array(document["resourceLogs"]).each do |resource|
          next unless resource.is_a?(Hash)

          Array(resource["scopeLogs"]).each do |scope|
            next unless scope.is_a?(Hash)

            Array(scope["logRecords"]).each { |record| yield record if record.is_a?(Hash) }
          end
        end
      end

      def attributes(list)
        Array(list).each_with_object({}) do |item, out|
          next unless item.is_a?(Hash) && item["key"].is_a?(String) && item["value"].is_a?(Hash)

          out[item["key"]] = item["value"]
        end
      end

      def api_request?(record, attributes)
        string(attributes["event.name"]) == EVENT_NAME || string(record["body"]) == EVENT_BODY
      end

      def event(record, attributes)
        session_id = string(attributes["session.id"])
        return [nil, "invalid_session"] unless session_id && Ids::SESSION_ID.match?(session_id)

        request_id = string(attributes["request_id"])
        return [nil, "missing_request_id"] unless request_id && REQUEST_ID.match?(request_id)

        ts = timestamp(attributes, record)
        return [nil, "missing_timestamp"] unless ts

        out = { "ts" => ts }
        STRINGS.each { |key, name| out[name] = clip(string(attributes[key])) }
        out["cost_usd"] = number(attributes["cost_usd"])
        INTEGERS.each { |key, name| out[name] = integer(attributes[key]) }
        [FIELDS.to_h { |name| [name, out[name]] }, nil]
      end

      def timestamp(attributes, record)
        text = string(attributes["event.timestamp"])
        return text if text && TIMESTAMP.match?(text)

        nanos = integer({ "intValue" => record["timeUnixNano"] })
        return nil unless nanos&.positive?

        Time.at(nanos / 1_000_000_000, nanos % 1_000_000_000, :nsec).utc.strftime("%Y-%m-%dT%H:%M:%S.%LZ")
      end

      def string(value)
        return value["stringValue"] if value.is_a?(Hash) && value["stringValue"].is_a?(String)

        nil
      end

      def clip(text)
        return nil if text.nil?

        text.bytesize > STRING_BYTES ? text.byteslice(0, STRING_BYTES).scrub("") : text
      end

      def integer(value)
        return nil unless value.is_a?(Hash)

        raw = value["intValue"]
        return raw if raw.is_a?(Integer)
        return Integer(raw, 10) if raw.is_a?(String) && raw.match?(/\A-?\d{1,19}\z/)

        nil
      end

      def number(value)
        return nil unless value.is_a?(Hash)

        raw = value["doubleValue"]
        return raw.to_f if raw.is_a?(Numeric) && raw.finite?
        return Float(raw) if raw.is_a?(String) && raw.match?(/\A-?\d+(\.\d+)?([eE][-+]?\d+)?\z/)

        integer(value)&.to_f
      end
    end
  end
end
