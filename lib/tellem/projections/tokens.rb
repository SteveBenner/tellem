# frozen_string_literal: true

require "json"
require "time"
require_relative "../record/fs"
require_relative "../record/reader"
require_relative "../record/schemas"
require_relative "../record/scope"
require_relative "../record/writer"

module Tellem
  module Projections
    module Tokens
      FIELDS = %w[
        timestamp session_id model input_tokens output_tokens cache_creation_input_tokens cache_read_input_tokens
        server_tool_use_web_search_requests server_tool_use_web_fetch_requests service_tier
        cache_creation_ephemeral_1h_input_tokens cache_creation_ephemeral_5m_input_tokens inference_geo speed
        total_tokens uuid stop_reason id cwd permission_mode stop_hook_active billing billing_plan provider agent_id
        reasoning_output_tokens
      ].freeze
      PASSTHROUGH = {
        "server_tool_use_web_search_requests" => 0,
        "server_tool_use_web_fetch_requests" => 0,
        "cache_creation_ephemeral_1h_input_tokens" => 0,
        "cache_creation_ephemeral_5m_input_tokens" => 0,
        "inference_geo" => "",
        "speed" => "standard",
        "uuid" => "",
        "permission_mode" => "",
        "billing" => "unknown",
        "billing_plan" => ""
      }.freeze
      INTEGER_FIELDS = %w[
        server_tool_use_web_search_requests server_tool_use_web_fetch_requests
        cache_creation_ephemeral_1h_input_tokens cache_creation_ephemeral_5m_input_tokens
      ].freeze
      USAGE = "usage"
      LEDGER = "ledger"
      MAIN = "main"
      STOPPED = "stopped"
      CODEX_FIXED = {
        "service_tier" => "", "cache_creation_ephemeral_1h_input_tokens" => 0, "cache_creation_ephemeral_5m_input_tokens" => 0,
        "inference_geo" => "", "speed" => "standard", "stop_reason" => nil
      }.freeze

      module_function

      def path(scope)
        Record::Scope.tokens_view(scope)
      end

      def refresh(scope, check: false)
        target = path(scope)
        list = rows(scope)
        bytes = render(list)
        current = read_current(target)
        changed = current != bytes
        Record::Writer.replace_atomic(target, bytes) if changed && !check
        { "path" => target, "rows" => list.size, "changed" => changed, "written" => changed && !check }
      end

      def render(list)
        list.map { |row| "#{JSON.generate(row)}\n" }.join
      end

      def read_current(target)
        Record::FS.read(target)
      rescue Errno::ENOENT, Errno::ENOTDIR
        nil
      end

      def rows(scope)
        usage = []
        superseded = {}
        places = {}
        stopped = {}
        lines = {}
        Record::Scope.session_keys(scope).each do |session_key|
          Record::Reader.each(Record::Scope.derived_path(scope, session_key)) do |record|
            next unless record["schema"] == Record::Schemas::DERIVED && record["session_key"] == session_key

            superseded[record["supersedes"]] = true if record["supersedes"].is_a?(String)
            case record["kind"]
            when USAGE then usage << record if usable?(record)
            when "place" then note_place(places, record)
            when "usage_line" then note_line(lines, record)
            when "lifecycle" then stopped[[session_key, record["agent_key"]]] = true if record.dig("body", "state") == STOPPED
            end
          end
        end
        chosen = streaming(pick(usage.reject { |record| superseded[record["id"]] }), stopped)
        chosen.sort_by { |record| [first_at(record), record["session_key"], record["body"]["request_key"]] }
              .map { |record| row(record, places, lines) }
      end

      def streaming(usage, stopped)
        last = {}
        usage.each do |record|
          next if record["agent_key"] == MAIN || harness(record) != "claude" || ledger_row(record["body"])

          key = [record["session_key"], record["agent_key"]]
          last[key] = record if last[key].nil? || first_at(record) >= first_at(last[key])
        end
        open = last.reject { |key, record| stopped[key] || !record["body"]["stop_reason"].nil? }.values
        usage - open
      end

      def first_at(record)
        string(record["body"]["first_line_at"]) || record["ts"]
      end

      def note_line(lines, record)
        body = record["body"]
        return unless body.is_a?(Hash) && body["line_at"].is_a?(String) && body["line_uuid"].is_a?(String)

        key = [body["harness"], body["request_key"]]
        current = lines[key]
        lines[key] = body if current.nil? || [body["line_at"], body["line_uuid"]].<=>([current["line_at"], current["line_uuid"]]).positive?
      end

      def line(record, lines)
        body = record["body"]
        return [string(body["first_line_at"]), string(body["first_line_uuid"])] if record["agent_key"] == MAIN

        last = lines[[harness(record), body["request_key"]]]
        last ? [last["line_at"], last["line_uuid"]] : [nil, nil]
      end

      def usable?(record)
        body = record["body"]
        body.is_a?(Hash) && body["request_key"].is_a?(String) && !body["request_key"].empty? &&
          record["ts"].is_a?(String) && record["session_key"].is_a?(String)
      end

      def note_place(places, record)
        body = record["body"]
        return unless body.is_a?(Hash) && body["place_id"].is_a?(String) && body["real_path"].is_a?(String)

        places[body["place_id"]] ||= body["real_path"]
      end

      def pick(usage)
        chosen = {}
        usage.each do |record|
          key = [harness(record), record["body"]["request_key"]]
          current = chosen[key]
          chosen[key] = record if current.nil? || (order(record) <=> order(current)).negative?
        end
        chosen.values
      end

      def order(record)
        [record["ts"].to_s, record["session_key"].to_s, record["id"].to_s]
      end

      def harness(record)
        value = record["body"]["harness"]
        return value if value.is_a?(String)

        record["session_key"].split("-", 2).first
      end

      def row(record, places, lines)
        body = record["body"]
        provider = harness(record)
        read = int(body["cache_read_input_tokens"])
        created = int(body["cache_creation_input_tokens"])
        output = int(body["output_tokens"])
        input = int(body["input_tokens"])
        input = [input - read - created, 0].max if provider == "codex"
        at, uuid = line(record, lines)
        values = {
          "timestamp" => timestamp(at || record["ts"]),
          "session_id" => string(body["session_id"]) || record["session_key"].split("-", 2).last,
          "model" => string(body["model"]) || "",
          "input_tokens" => input,
          "output_tokens" => output,
          "cache_creation_input_tokens" => created,
          "cache_read_input_tokens" => read,
          "service_tier" => string(body["service_tier"]) || "",
          "total_tokens" => input + output + created + read,
          "stop_reason" => string(body["stop_reason"]),
          "id" => string(body["ledger_id"]) || body["request_key"],
          "cwd" => string(body["cwd"]) || places[body["place_id"]] || "",
          "stop_hook_active" => body["stop_hook_active"] == true,
          "provider" => provider,
          "agent_id" => agent_id(record),
          "reasoning_output_tokens" => int(body["reasoning_tokens"])
        }
        PASSTHROUGH.each { |field, fallback| values[field] = passthrough(body[field], fallback, field) }
        values["uuid"] = uuid || ""
        values.merge!(CODEX_FIXED) if provider == "codex"
        carried = ledger_row(body)
        FIELDS.to_h { |field| [field, carried&.key?(field) ? carried[field] : values[field]] }
      end

      def ledger_row(body)
        body["source"] == LEDGER && body["ledger_row"].is_a?(Hash) ? body["ledger_row"] : nil
      end

      def passthrough(value, fallback, field)
        if INTEGER_FIELDS.include?(field)
          value.is_a?(Integer) ? value : fallback
        else
          string(value) || fallback
        end
      end

      def agent_id(record)
        key = record["agent_key"]
        key.is_a?(String) && key != MAIN ? key : ""
      end

      def int(value)
        value.is_a?(Integer) ? value : 0
      end

      def string(value)
        value.is_a?(String) ? value : nil
      end

      def timestamp(ts)
        Time.iso8601(ts).utc.strftime("%Y-%m-%dT%H:%M:%SZ")
      rescue ArgumentError
        ts.sub(/\.\d+Z\z/, "Z")
      end
    end
  end
end
