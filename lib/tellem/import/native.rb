# frozen_string_literal: true

require "json"
require_relative "../errors"
require_relative "../ids"
require_relative "../seams"
require_relative "../deriver/run"
require_relative "../deriver/sources"
require_relative "../deriver/cursor"
require_relative "candidate"
require_relative "files"

module Tellem
  module Import
    module Native
      SOURCE = "native"
      CLAUDE_NAME = /\A[A-Za-z0-9_-]{1,200}\.jsonl\z/
      ROLLOUT = /\Arollout-.+\.jsonl\z/
      ROLLOUT_ID = /-([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.jsonl\z/
      SUBAGENTS = "subagents"

      PlanContext = Struct.new(:harness)
      PlanSession = Struct.new(:batches, :natives, :session_id, :context)

      module_function

      def candidates(paths, harness, skipped)
        found = {}
        files(paths, harness).each do |path|
          candidate = ROLLOUT.match?(File.basename(path)) ? codex(path, harness, skipped) : claude(path, harness, skipped)
          next unless candidate

          if found.key?(candidate.session_key)
            skipped << { "path" => path, "cause" => "duplicate_session", "session_key" => candidate.session_key }
          else
            found[candidate.session_key] = candidate
          end
        end
        found.values
      end

      def files(paths, harness)
        return default_files(harness) if paths.empty?

        paths.flat_map do |path|
          if Files.regular?(path)
            [path]
          elsif File.directory?(path)
            Files.jsonl(path).select { |file| transcript_name?(file) }
          else
            raise UsageError.new("no file or directory at #{path}", next_command: "tellem import native --path PATH")
          end
        end.uniq
      end

      def default_files(harness)
        claude = Array(harness.claude_transcripts).select { |path| transcript_name?(path) }
        (claude + Array(harness.codex_rollouts)).uniq
      end

      def transcript_name?(path)
        return false if File.basename(File.dirname(path)) == SUBAGENTS

        name = File.basename(path)
        ROLLOUT.match?(name) || CLAUDE_NAME.match?(name)
      end

      def claude(path, harness, skipped)
        session_id = File.basename(path, ".jsonl")
        key = Ids.session_key("claude", session_id)
        return skip(skipped, path, "invalid_session_id") unless key

        cwd = claude_cwd(path)
        return skip(skipped, path, "no_cwd") unless cwd

        natives = Deriver::Sources.discover(PlanContext.new(harness), "claude", session_id, path)
      rescue Deriver::Sources::HarnessUnreadable
        skip(skipped, path, Deriver::Sources::UNREADABLE)
      else
        build(key, "claude", session_id, Homes.root_for(key, cwd), path, natives)
      end

      def claude_cwd(path)
        Files.each_line(path) do |line|
          next unless line.include?("\"cwd\"")

          entry = parse(line)
          cwd = entry.is_a?(Hash) ? entry["cwd"] : nil
          return cwd if cwd.is_a?(String) && cwd.start_with?("/")
        end
        nil
      end

      def codex(path, harness, skipped)
        payload = codex_head(path)
        return skip(skipped, path, "no_session_meta") unless payload
        return nil if child?(payload)

        session_id = text(payload["session_id"]) || text(payload["id"])
        key = Ids.session_key("codex", session_id)
        return skip(skipped, path, "invalid_session_id") unless key

        cwd = text(payload["cwd"])
        return skip(skipped, path, "no_cwd") unless cwd&.start_with?("/")

        natives = codex_natives(path, session_id, harness)
      rescue Deriver::Sources::HarnessUnreadable
        skip(skipped, path, Deriver::Sources::UNREADABLE)
      else
        build(key, "codex", session_id, Homes.root_for(key, cwd), path, natives)
      end

      def codex_head(path)
        entry = parse(Files.first_line(path).to_s)
        return nil unless entry.is_a?(Hash) && entry["type"] == "session_meta" && entry["payload"].is_a?(Hash)

        entry["payload"]
      end

      def child?(payload)
        source = payload["source"].is_a?(Hash) ? payload["source"] : {}
        spawn = source.dig("subagent", "thread_spawn") if source["subagent"].is_a?(Hash)
        return true if text(payload["parent_thread_id"]) || (spawn.is_a?(Hash) && text(spawn["parent_thread_id"]))

        session_id = text(payload["session_id"])
        !session_id.nil? && !text(payload["id"]).nil? && session_id != payload["id"]
      end

      def codex_natives(path, session_id, harness)
        reader = Seams.fetch(:ingest_codex)
        main = Deriver::Cursor.stat(path)
        session = PlanSession.new({}, { Ids::MAIN_AGENT => main }, session_id, PlanContext.new(harness))
        session.batches[Ids::MAIN_AGENT] = reader.read(path, session_id: session_id, agent_key: Ids::MAIN_AGENT)
        Deriver::Sources.codex_descendants(session) do |agent|
          session.batches[agent] = reader.read(session.natives[agent]["path"], session_id: session_id, agent_key: agent)
        end
        session.natives
      end

      def build(key, harness, session_id, home, main, natives)
        agents = natives.keys.sort_by { |agent| [agent == Ids::MAIN_AGENT ? 0 : 1, agent] }
        Candidate.new(session_key: key, harness: harness, session_id: session_id, home_root: home, source: SOURCE,
                      files: agents.map { |agent| natives[agent]["path"] }, data: { "main" => main, "items" => agents })
      end

      def claude_ids(harness)
        Array(harness.claude_transcripts).select { |path| transcript_name?(path) && CLAUDE_NAME.match?(File.basename(path)) }
                                         .to_h { |path| [File.basename(path, ".jsonl"), true] }
      end

      def codex_ids(harness)
        Array(harness.codex_rollouts).filter_map { |path| ROLLOUT_ID.match(File.basename(path))&.[](1) }.to_h { |id| [id, true] }
      end

      def skip(skipped, path, cause)
        skipped << { "path" => path, "cause" => cause }
        nil
      end

      def parse(line)
        JSON.parse(line)
      rescue JSON::ParserError, EncodingError
        nil
      end

      def text(value)
        value.is_a?(String) && !value.empty? ? value : nil
      end
    end
  end
end
