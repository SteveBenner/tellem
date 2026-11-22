# frozen_string_literal: true

require_relative "../errors"
require_relative "../ids"
require_relative "../record/reader"
require_relative "../record/scope"
require_relative "turns"

module Tellem
  module Parity
    module Rollout
      ROLES = { "user" => "User", "assistant" => "Agent" }.freeze
      COUNTERS = {
        "input_tokens" => "input_tokens",
        "output_tokens" => "output_tokens",
        "cache_read_input_tokens" => "cached_input_tokens",
        "cache_creation_input_tokens" => "cache_write_input_tokens",
        "reasoning_output_tokens" => "reasoning_output_tokens",
        "total_tokens" => "total_tokens"
      }.freeze
      SEPARATOR = "\n\n---\n\n"
      NO_REFERENCE = "no_incumbent"
      CUMULATIVE_DIFFERS = "rollout_cumulative_differs_from_requests"
      INPUT = "input_tokens"
      CACHED = "cached_input_tokens"

      module_function

      def path(root, key)
        found = nil
        Record::Reader.each(File.join(Record::Scope.raw_dir(root, key), "#{Ids::MAIN_AGENT}.jsonl")) do |record|
          value = record["transcript_path"]
          found = value if value.is_a?(String) && value.start_with?("/")
        end
        found
      rescue SystemCallError, SymlinkRefused
        nil
      end

      def compare(root, key, tellem_text, rows)
        file = path(root, key)
        return missing("rollout_path_unknown") unless file

        reference = reference(file)
        return missing("rollout_unreadable") unless reference

        { "path" => file, "modified" => File.mtime(file).utc.strftime("%Y-%m-%dT%H:%M:%SZ"),
          "transcripts" => transcripts(tellem_text, reference), "tokens" => tokens(rows, reference) }
      rescue SystemCallError, SymlinkRefused
        missing("rollout_unreadable")
      end

      def missing(reason)
        { "path" => nil, "problem" => reason, "transcripts" => { "verdict" => NO_REFERENCE, "causes" => [] },
          "tokens" => { "verdict" => NO_REFERENCE, "causes" => [] } }
      end

      def reference(file)
        turns = []
        requests = []
        charged = []
        cumulative = nil
        previous = nil
        Record::Reader.each(file) do |entry|
          payload = entry["payload"]
          next unless payload.is_a?(Hash)

          case entry["type"]
          when "response_item"
            turn = message(payload)
            turns << turn if turn
          when "token_usage_record"
            requests << payload["usage"] if payload["usage"].is_a?(Hash)
          when "event_msg"
            info = payload["type"] == "token_count" ? payload["info"] : nil
            next unless info.is_a?(Hash) && info["total_token_usage"].is_a?(Hash)

            total = info["total_token_usage"]
            charged << info["last_token_usage"] if total != previous && info["last_token_usage"].is_a?(Hash)
            previous = total
            cumulative = total
          end
        end
        { "markdown" => turns.join(SEPARATOR), "requests" => requests.map { |usage| uncached(usage) },
          "charged" => charged.map { |usage| uncached(usage) }, "cumulative" => cumulative && uncached(cumulative) }
      end

      def uncached(usage)
        usage.merge(INPUT => usage[INPUT].to_i - usage[CACHED].to_i)
      end

      def message(payload)
        role = ROLES[payload["role"].to_s]
        return nil unless payload["type"] == "message" && role

        parts = payload["content"].is_a?(Array) ? payload["content"] : [payload["content"]]
        text = parts.filter_map { |part| part.is_a?(Hash) ? part["text"] : part }.grep(String).join("\n").strip
        text.empty? ? nil : "_**#{role}**_\n\n#{text}"
      end

      def transcripts(tellem_text, reference)
        return { "verdict" => NO_REFERENCE, "causes" => [{ "cause" => "tellem_transcript_missing" }] } if tellem_text.nil?

        result = Turns.compare(tellem_text, reference["markdown"], tools: false)
        relabel(result)
      end

      def relabel(result)
        turns = result["turns"]
        result = result.merge("turns" => { "tellem" => turns["tellem"], "rollout" => turns["specstory"] })
        result.merge("causes" => result["causes"].map { |cause| relabel_cause(cause) })
      end

      def relabel_cause(cause)
        return cause unless cause.key?("specstory")

        cause.reject { |name, _| name == "specstory" }.merge("rollout" => cause["specstory"])
      end

      def tokens(rows, reference)
        mine = rows.select { |row| row["agent_id"].to_s.empty? }
        source = reference["requests"].empty? ? reference["charged"] : reference["requests"]
        sums = COUNTERS.to_h { |counter, field| [counter, { "tellem" => total(mine, counter), "rollout" => total(source, field) }] }
        causes = []
        causes << { "cause" => "request_count_differs", "tellem" => mine.size, "rollout" => source.size } if mine.size != source.size
        sums.each do |counter, pair|
          causes << { "cause" => "counter_sum_differs", "counter" => counter }.merge(pair) if pair["tellem"] != pair["rollout"]
        end
        { "verdict" => causes.empty? ? "match" : "mismatch", "rows" => { "tellem" => mine.size, "rollout" => source.size },
          "sums" => sums, "causes" => causes, "accepted" => accepted(reference, sums) }
      end

      def accepted(reference, sums)
        cumulative = reference["cumulative"]
        return [] if reference["requests"].empty? || cumulative.nil?

        differing = COUNTERS.filter_map do |counter, field|
          pair = { "requests" => sums[counter]["rollout"], "cumulative" => cumulative[field].to_i }
          [counter, pair] if pair["requests"] != pair["cumulative"]
        end
        differing.empty? ? [] : [{ "reason" => CUMULATIVE_DIFFERS, "count" => 1, "sample" => differing.to_h }]
      end

      def total(rows, field)
        rows.sum { |row| row[field].is_a?(Integer) ? row[field] : 0 }
      end
    end
  end
end
