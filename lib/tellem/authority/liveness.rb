# frozen_string_literal: true

require "json"
require "time"
require_relative "../deriver/spool"
require_relative "../ids"
require_relative "../ingest/claude_bodies"
require_relative "../otel/settings"
require_relative "../ports/harness_paths"
require_relative "../record/fs"
require_relative "../record/reader"
require_relative "restore"
require_relative "state"

module Tellem
  module Authority
    module Liveness
      HARNESS = "claude"
      LOST = "capture_lost"
      INEFFECTIVE = "level_ineffective"
      FIRST_RESPONSE_S = 30
      QUIET_S = 300
      LOST_GAPS = { "body_missing" => "body_missing", "body_marked" => "body_marked", "body_too_large" => "body_too_large",
                    Ingest::ClaudeBodies::UNSAFE => "spool_unsafe" }.freeze
      SIDEBAND = Ingest::ClaudeBodies::SIDEBAND
      RESPONSE_EVENTS = %w[post_tool subagent_stop].freeze

      module_function

      def run(context, sessions, totals)
        return unless State.level(HARNESS) == State::OWN

        applied = State.applied_ns(HARNESS)
        eligible = sessions.select { |session| eligible?(session, applied) }
        unsafe = Ingest::ClaudeBodies.unsafe_reason(Ports::HarnessPaths.body_spool)
        return lose(eligible.max_by { |session| session.first_ts.to_s }, LOST, "spool_#{unsafe}", totals) if unsafe

        eligible.each do |session|
          kind, reason = verdict(session, context)
          next unless kind

          lose(session, kind, reason, totals)
          break
        end
      end

      def eligible?(session, applied)
        return false unless session.harness == HARNESS && !session.failed

        first = session.all_raw.first&.fetch("ts", nil)
        first.is_a?(String) && (applied.nil? || (Time.iso8601(first).to_r * State::NS).to_i >= applied)
      rescue ArgumentError
        false
      end

      def verdict(session, context)
        main = session.natives[Ids::MAIN_AGENT]
        return [INEFFECTIVE, "native_transcript_present"] if main && !Deriver::Spool.held?(session, main)
        return [LOST, "native_file_present"] if native_on_disk?(session)

        gap = session.of("gap").map { |record| record.dig("body", "cause") }.find { |cause| LOST_GAPS.key?(cause) }
        return [LOST, LOST_GAPS.fetch(gap)] if gap && (gap != "body_missing" || over?(session))

        lines = index_lines(session.session_id)
        marks = evidence(session)
        return no_index(session, marks) if lines.empty?
        return nil unless over?(session)

        missing = marks[:requests] - lines
        return [LOST, "fewer_bodies_than_responses"] unless missing.empty?

        held = held_tools(context, session)
        lost_tools = marks[:tools].reject { |id| held[id] }
        return [LOST, "tool_call_without_body"] unless lost_tools.empty?

        nil
      end

      def native_on_disk?(session)
        path = session.all_raw.reverse.find { |record| record["transcript_path"].is_a?(String) }&.fetch("transcript_path", nil)
        path && Record::FS.lstat(path)&.file?
      end

      def no_index(session, marks)
        first = first_evidence(session, marks)
        return nil unless first

        latency = latency(session, first)
        return [LOST, "no_index_line"] if Record::FS.now_ns >= ns(first) + ((latency + FIRST_RESPONSE_S) * State::NS)

        session.overdue?(Record::FS.rfc3339_ms(Record::FS.now_ns))
        nil
      end

      def first_evidence(session, marks)
        times = session.all_raw.select { |record| RESPONSE_EVENTS.include?(record["event"]) }.map { |record| record["ts"] }
        times += marks[:times]
        stop = session.all_raw.find { |record| record["event"] == "stop" }
        times << stop["ts"] if stop && !interrupted_only?(session)
        times.grep(String).min
      end

      def interrupted_only?(session)
        orphan_requests(session.session_id).positive?
      end

      def orphan_requests(session_id)
        dir = Ports::HarnessPaths.body_spool
        named = {}
        Record::Reader.each(File.join(dir, Ingest::ClaudeBodies::INDEX)) { |line| named[File.basename(line["request_file"])] = true if line["request_file"].is_a?(String) }
        Dir.children(dir).count do |name|
          next false unless Ingest::ClaudeBodies::REQUEST_FILE.match?(name) && !named[name]

          owner(dir, name) == session_id
        end
      rescue SystemCallError
        0
      end

      def owner(dir, name)
        path = File.join(dir, name)
        return nil if File.lstat(path).size > Ingest::ClaudeBodies::BODY_BYTES

        Ingest::ClaudeBodies.owner(JSON.parse(Record::FS.read(path)))
      rescue JSON::ParserError, EncodingError, SystemCallError, SymlinkRefused
        nil
      end

      def latency(session, first)
        prompt = session.all_raw.find { |record| record["event"] == "prompt_submit" }&.fetch("ts", nil)
        return 0 unless prompt.is_a?(String) && prompt <= first

        (ns(first) - ns(prompt)) / State::NS
      end

      def ns(text)
        (Time.iso8601(text).to_r * State::NS).to_i
      end

      def over?(session)
        return true if session.stopped?

        newest = session.all_raw.last&.fetch("ts", nil)
        newest.is_a?(String) && Record::FS.now_ns >= ns(newest) + (QUIET_S * State::NS)
      end

      def index_lines(session_id)
        ids = []
        Record::Reader.each(File.join(Ports::HarnessPaths.body_spool, Ingest::ClaudeBodies::INDEX)) do |line|
          ids << line["request_id"] if line["session_id"] == session_id && line["request_id"].is_a?(String)
        end
        ids
      rescue SystemCallError
        []
      end

      def evidence(session)
        requests = []
        times = []
        path = Otel::Settings.spool(session.key)
        if Record::FS.lstat(path)&.file?
          Record::Reader.each(path) do |event|
            next if SIDEBAND.include?(event["query_source"])

            requests << event["request_id"] if event["request_id"].is_a?(String)
            times << event["ts"] if event["ts"].is_a?(String)
          end
        end
        tools = session.all_raw.select { |record| record["event"] == "post_tool" }.filter_map { |record| record["tool_use_id"] }
        { requests: requests.uniq, times: times, tools: tools.uniq }
      end

      def held_tools(_context, session)
        lines, = Deriver::Spool.held_lines(session)
        lines.values.flatten.each_with_object({}) do |line, out|
          Array(line.dig("message", "content")).each do |block|
            out[block["id"]] = true if block.is_a?(Hash) && block["type"] == "tool_use"
          end
        end
      end

      def lose(session, kind, reason, totals)
        note(session, kind, "authority/#{reason}", { "reason" => reason, "level" => State::OWN }, totals)
        outcome = Restore.lost(kind, reason, session_key: session&.key)
        return outcome unless Restore.failed?(outcome)

        note(session, Restore::FAILED, "authority/#{outcome['error']}",
             { "kind" => outcome["kind"], "reason" => outcome["reason"], "error" => outcome["error"], "file" => outcome["file"], "level" => State::OWN }, totals)
        totals.errors << { "phase" => "authority", "error_class" => outcome["error"], "message" => outcome["message"].to_s[0, 200] }
        outcome
      end

      def note(session, cause, suffix, detail, totals)
        return unless session

        session.gap(cause, suffix, agent_key: Ids::MAIN_AGENT, ts: session.first_ts || Record::FS.rfc3339_ms(0), detail: detail)
        totals.absorb(session.flush)
      end
    end
  end
end
