# frozen_string_literal: true

require "json"
require_relative "../errors"
require_relative "../ids"
require_relative "../record/scope"
require_relative "../deriver/session"
require_relative "candidate"
require_relative "files"
require_relative "records"

module Tellem
  module Import
    module Ledger
      SOURCE = "ledger"
      FILE = "TOKENS.jsonl"
      UNKNOWN_PERSONA = "unknown"
      CLAUDE_MODEL = "claude-"
      STRINGS = %w[stop_reason inference_geo speed permission_mode billing cwd].freeze
      INTEGERS = %w[
        cache_creation_ephemeral_1h_input_tokens cache_creation_ephemeral_5m_input_tokens
        server_tool_use_web_search_requests server_tool_use_web_fetch_requests
      ].freeze

      module_function

      def candidates(paths, skipped, ledgers)
        found = {}
        files(paths).each do |path|
          causes = Hash.new(0)
          entries = []
          Files.json_lines(path).each do |line, row|
            entry = parse(path, line, row)
            entry.is_a?(String) ? causes[entry] += 1 : entries << entry
          end
          kept, collapsed = collapse(entries)
          kept.each { |entry| add(found, path, entry) }
          causes.sort.each { |cause, count| skipped << { "path" => path, "cause" => cause, "rows" => count } }
          ledgers << { "path" => path, "rows" => entries.size, "duplicate_ids" => collapsed.size,
                       "rows_collapsed" => collapsed.values.sum }
        end
        found.values
      end

      def files(paths)
        return [File.join(Record::Scope.locate(Dir.pwd), FILE)].select { |path| Files.regular?(path) } if paths.empty?

        paths.map do |path|
          if Files.regular?(path)
            path
          elsif File.directory?(path) && Files.regular?(File.join(path, FILE))
            File.join(path, FILE)
          else
            raise UsageError.new("no ledger file at #{path}", next_command: "tellem import ledger --path PATH")
          end
        end.uniq
      end

      def collapse(entries)
        groups = entries.group_by { |entry| string(entry[:item]["row"]["id"]) }
        keep = {}
        collapsed = {}
        groups.each do |id, list|
          next if id.nil? || list.size < 2

          keep[id] = list.min_by { |entry| [entry[:item]["ts"], entry[:key], entry[:item]["line"]] }
          collapsed[id] = list.size - 1
        end
        kept = entries.select do |entry|
          id = string(entry[:item]["row"]["id"])
          id.nil? || !keep.key?(id) || keep[id].equal?(entry)
        end
        [kept, collapsed]
      end

      def parse(path, line, row)
        return "unparseable_row" unless row.is_a?(Hash)

        harness, inferred = provider(row)
        return "unknown_model" if harness.nil? && !inferred
        return "unknown_provider" unless Ids::HARNESSES.include?(harness)

        key = Ids.session_key(harness, row["session_id"])
        return "invalid_session_id" unless key

        ts = Files.iso_ms(row["timestamp"])
        return "invalid_timestamp" unless ts

        agent = Ids.agent_key(row["agent_id"].is_a?(String) ? row["agent_id"] : nil)
        return "invalid_agent_id" unless agent

        { key: key, harness: harness,
          item: { "path" => path, "line" => line, "row" => row, "ts" => ts, "agent_key" => agent, "provider_inferred" => inferred } }
      end

      def add(found, path, entry)
        key = entry[:key]
        row = entry[:item]["row"]
        candidate = found[key] ||= Candidate.new(session_key: key, harness: entry[:harness], session_id: row["session_id"],
                                                 home_root: Homes.root_for(key, File.dirname(path)), source: SOURCE,
                                                 files: [], data: { "items" => [] })
        candidate.files << path unless candidate.files.include?(path)
        candidate.data["items"] << entry[:item]
      end

      def provider(row)
        return [row["provider"], false] if row.key?("provider") && !row["provider"].nil?

        model = row["model"]
        model.is_a?(String) && model.start_with?(CLAUDE_MODEL) ? ["claude", true] : [nil, false]
      end

      def keys(root)
        path = File.join(root, FILE)
        return {} unless Files.regular?(path)

        Files.json_lines(path).each_with_object({}) do |(_line, row), out|
          next unless row.is_a?(Hash)

          key = Ids.session_key(provider(row).first, row["session_id"])
          out[key] = true if key
        end
      end

      def apply(context, candidates, totals)
        candidates.each do |candidate|
          session = Deriver::Session.new(context, candidate.session_key)
          items = candidate.data["items"]
          Records.session(session, candidate, items.map { |item| item["ts"] }.min)
          items.each { |item| usage(session, candidate, item) }
          totals.session(session.key)
          totals.absorb(session.flush)
        end
      end

      def usage(session, candidate, item)
        row = item["row"]
        cwd = string(row["cwd"])
        place = cwd&.start_with?("/") ? session.local_place(cwd, agent_key: item["agent_key"], ts: item["ts"]) : nil
        body = counters(candidate.harness, row).merge(extras(row)).merge(
          "harness" => candidate.harness, "request_key" => request_key(row), "model" => string(row["model"]),
          "service_tier" => string(row["service_tier"]), "first_line_at" => item["ts"], "first_line_uuid" => string(row["uuid"]),
          "ledger_id" => string(row["id"]), "subagent_type" => nil, "effort" => nil, "persona" => nil,
          "persona_key" => UNKNOWN_PERSONA, "repository_id" => place && place["repository_id"],
          "place_id" => place && place["place_id"], "source" => SOURCE, "ledger_row" => row
        )
        body["provider_inferred"] = true if item["provider_inferred"]
        session.add("usage", agent_key: item["agent_key"], ts: item["ts"], body: body)
      end

      def counters(harness, row)
        input = integer(row["input_tokens"])
        output = integer(row["output_tokens"])
        read = integer(row["cache_read_input_tokens"])
        created = integer(row["cache_creation_input_tokens"])
        if harness == "codex"
          input += read + created if input && read && created
          return { "input_tokens" => input, "output_tokens" => output, "cache_read_input_tokens" => read,
                   "cache_creation_input_tokens" => created, "reasoning_tokens" => integer(row["reasoning_output_tokens"]),
                   "total_tokens" => integer(row["total_tokens"]) }
        end

        parts = [input, output, read, created]
        { "input_tokens" => input, "output_tokens" => output, "cache_read_input_tokens" => read,
          "cache_creation_input_tokens" => created, "reasoning_tokens" => nil, "total_tokens" => parts.all? ? parts.sum : nil }
      end

      def extras(row)
        STRINGS.to_h { |field| [field, string(row[field])] }.merge(INTEGERS.to_h { |field| [field, integer(row[field])] })
      end

      def request_key(row)
        string(row["id"]) || "ledger:#{Ids.sha256(JSON.generate(row))[0, 32]}"
      end

      def integer(value)
        value.is_a?(Integer) ? value : nil
      end

      def string(value)
        value.is_a?(String) && !value.empty? ? value : nil
      end
    end
  end
end
