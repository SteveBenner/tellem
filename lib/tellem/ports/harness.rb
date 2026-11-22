# frozen_string_literal: true

require "date"
require "json"
require "open3"
require_relative "harness_paths"

module Tellem
  module Ports
    class Harness < Rplugin::Ports::Base
      VERSION_COMMANDS = { "claude" => %w[claude --version], "codex" => %w[codex --version] }.freeze
      VERSION_TIMEOUT_S = 3
      HEAD_BYTES = 4 * 1024 * 1024

      def initialize(plugin_id:, fallback: nil, root: nil, events: nil)
        super
        @versions = {}
      end

      def paths
        HarnessPaths.all
      end

      def claude_subagent_transcripts(main_transcript_path, session_id)
        return [] unless main_transcript_path.is_a?(String) && session_id.is_a?(String)
        return [] unless session_id.match?(/\A[A-Za-z0-9_-]{1,200}\z/)

        dir = File.join(File.dirname(File.expand_path(main_transcript_path)), session_id, "subagents")
        Dir.glob(File.join(dir, "agent-*.jsonl")).select { |path| regular?(path) }.sort
      end

      def claude_transcripts(since: nil)
        files = Dir.glob(File.join(HarnessPaths.claude_projects, "*", "*.jsonl"))
        files += Dir.glob(File.join(HarnessPaths.claude_projects, "*", "*", "subagents", "agent-*.jsonl"))
        filter(files, since).sort
      end

      def codex_rollouts(session_id: nil, since: nil)
        files = Dir.glob(File.join(HarnessPaths.codex_sessions, "*", "*", "*", "rollout-*.jsonl"))
        files = files.select { |path| File.basename(path, ".jsonl").end_with?("-#{session_id}") } if session_id
        filter(files, since).sort
      end

      def codex_thread_heads(day)
        dir = File.join(HarnessPaths.codex_sessions, day.strftime("%Y"), day.strftime("%m"), day.strftime("%d"))
        Dir.glob(File.join(dir, "rollout-*.jsonl")).select { |path| regular?(path) }.sort.filter_map do |path|
          head = rollout_head(path)
          head&.merge("path" => path)
        end
      end

      def harness_version(harness)
        key = harness.to_s
        return @versions[key] if @versions.key?(key)

        @versions[key] = probe_version(key)
      end

      def harness_binary(harness)
        argv = VERSION_COMMANDS[harness.to_s]
        argv && executable_path(argv.first)
      end

      def specstory_detected?
        executable?("specstory")
      end

      def ai_home
        HarnessPaths.ai_home
      end

      def spawn_tools(harness)
        HarnessPaths.spawn_tools(harness)
      end

      private

      def regular?(path)
        File.lstat(path).file?
      rescue SystemCallError
        false
      end

      def rollout_head(path)
        line = File.open(path, "rb") { |io| io.gets("\n", HEAD_BYTES) }
        return nil unless line&.end_with?("\n")

        payload = JSON.parse(line)["payload"]
        return nil unless payload.is_a?(Hash)

        source = payload["source"].is_a?(Hash) ? payload["source"] : {}
        subagent = source["subagent"].is_a?(Hash) ? source["subagent"] : {}
        spawn = subagent["thread_spawn"].is_a?(Hash) ? subagent["thread_spawn"] : {}
        {
          "id" => text(payload["id"]), "session_id" => text(payload["session_id"]),
          "parent_thread_id" => text(payload["parent_thread_id"]) || text(spawn["parent_thread_id"]),
          "source" => text(subagent["other"]) || (spawn.empty? ? nil : "thread_spawn")
        }
      rescue SystemCallError, JSON::ParserError, ArgumentError
        nil
      end

      def text(value)
        value.is_a?(String) && !value.empty? ? value : nil
      end

      def filter(files, since)
        files = files.select { |path| regular?(path) }
        return files unless since

        cutoff = since.is_a?(Time) ? since : Time.at(since.to_i)
        files.select { |path| File.mtime(path) >= cutoff }
      end

      def probe_version(harness)
        argv = VERSION_COMMANDS[harness]
        return nil unless argv && executable?(argv.first)

        output = run_bounded(argv)
        output && output[/\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?/]
      end

      def run_bounded(argv)
        Open3.popen2(*argv, err: File::NULL, pgroup: true) do |stdin, stdout, wait|
          stdin.close
          if stdout.wait_readable(VERSION_TIMEOUT_S) && wait.join(VERSION_TIMEOUT_S)
            stdout.read.to_s
          else
            kill_group(wait.pid)
            nil
          end
        end
      rescue SystemCallError, IOError
        nil
      end

      def kill_group(pid)
        Process.kill("KILL", -pid)
      rescue SystemCallError
        nil
      end

      def executable?(name)
        !executable_path(name).nil?
      end

      def executable_path(name)
        ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).map { |dir| File.join(dir, name) }.find do |path|
          File.file?(path) && File.executable?(path)
        end
      end
    end
  end
end
