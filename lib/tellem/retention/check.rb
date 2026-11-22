# frozen_string_literal: true

require_relative "../ids"
require_relative "../ports/harness_paths"
require_relative "../record/fs"
require_relative "../record/kinds"
require_relative "../record/scope"
require_relative "../deriver/cursor"
require_relative "../deriver/session"
require_relative "../deriver/sources"
require_relative "../deriver/spool"
require_relative "tool_counts"

module Tellem
  module Retention
    module Check
      SIDE_ENTRIES = %w[subagents tool-results].freeze
      CLAUDE = "claude"
      NS = 1_000_000_000
      QUIET_FLOOR_S = 86_400
      FINAL_WAIT = %w[not_final unsettled transcript_not_final].freeze

      Result = Struct.new(:session_key, :state, :condition, :files, :dirs, :newest_ns, :session, :requests, :counters, :detail,
                          keyword_init: true)

      module_function

      def evaluate(context, key, window_s, session: nil, now_ns: Record::FS.now_ns)
        harness, session_id = key.split("-", 2)
        return nil unless harness == CLAUDE

        main = context.cursor.natives(key).dig(Ids::MAIN_AGENT, "path")
        return Result.new(session_key: key, state: "gone") unless main.is_a?(String) && Record::FS.lexists?(main)
        return Result.new(session_key: key, state: "gone") if File.dirname(main) == Deriver::Spool.held_dir(context.root, key)

        walk = walk(main, session_id)
        result = Result.new(session_key: key, files: walk[:files], dirs: walk[:dirs], newest_ns: walk[:newest_ns])
        window = window_s.respond_to?(:call) ? window_s.call(walk[:newest_ns]) : window_s
        return waiting(result, "older_than_plan") if window.nil?
        return waiting(result, "window") if walk[:newest_ns] >= now_ns - (window * NS)

        result.session, unreadable = session ? [session, nil] : load(context, key, session_id, main)
        condition = walk[:problem] || unreadable || conditions(context, result, window, now_ns)
        return waiting(result, condition) if window.zero? && FINAL_WAIT.include?(condition)

        result.state = condition ? "held" : "candidate"
        result.condition = condition
        result
      end

      def waiting(result, condition)
        result.state = "waiting"
        result.condition = condition
        result
      end

      def load(context, key, session_id, main)
        session = Deriver::Session.new(context, key)
        Deriver::Sources.load_raw(session)
        session.natives.merge!(Deriver::Sources.discover(context, CLAUDE, session_id, main))
        [session, nil]
      rescue Deriver::Sources::HarnessUnreadable
        [session, Deriver::Sources::UNREADABLE]
      end

      def walk(main, session_id)
        state = { files: [], dirs: [], newest_ns: 0, problem: nil }
        root = transcript_root
        return state.merge(problem: "no_transcript_root") unless root

        state[:problem] ||= "unexpected_name" unless File.basename(main) == "#{session_id}.jsonl"
        state[:problem] ||= "outside_root" unless inside?(File.dirname(main), root)
        entry(state, main, root)
        side = File.join(File.dirname(main), session_id)
        stat = Record::FS.lstat(side)
        return state unless stat

        if stat.symlink? || !stat.directory?
          state[:problem] ||= stat.symlink? ? "symlink" : "not_regular"
          note(state, stat)
          return state
        end
        state[:problem] ||= "outside_root" unless inside?(side, root)
        Dir.children(side).sort.each do |name|
          state[:problem] ||= "unexpected_entry" unless SIDE_ENTRIES.include?(name)
          tree(state, File.join(side, name), root)
        end
        state[:dirs] << side
        state
      end

      def tree(state, path, root)
        stat = Record::FS.lstat(path)
        return unless stat

        if stat.directory? && !stat.symlink?
          state[:problem] ||= "outside_root" unless inside?(path, root)
          Dir.children(path).sort.each { |name| tree(state, File.join(path, name), root) }
          state[:dirs] << path
        else
          entry(state, path, root, stat)
        end
      end

      def entry(state, path, _root, stat = Record::FS.lstat(path))
        return unless stat

        state[:problem] ||= "symlink" if stat.symlink?
        state[:problem] ||= "not_regular" unless stat.symlink? || stat.file?
        note(state, stat)
        state[:files] << { "path" => path, "inode" => stat.ino, "size" => stat.size, "mtime_ns" => mtime_ns(stat) } if stat.file?
      end

      def note(state, stat)
        state[:newest_ns] = [state[:newest_ns], mtime_ns(stat)].max
      end

      def mtime_ns(stat)
        (stat.mtime.to_r * NS).to_i
      end

      def transcript_root
        File.realpath(Ports::HarnessPaths.claude_projects)
      rescue SystemCallError
        nil
      end

      def inside?(path, root)
        File.realpath(path).start_with?("#{root}/")
      rescue SystemCallError
        false
      end

      def conditions(context, result, window_s, now_ns)
        session = result.session
        return "not_final" unless session.stopped? || raw_quiet?(session, [window_s, QUIET_FLOOR_S].max, now_ns)
        return "unsettled" if session.unsettled || context.cursor.session(session.key)["unsettled"] == true
        return "transcript_not_final" unless transcripts_final?(context, session)

        usage(context, result) || ToolCounts.condition(context, result)
      end

      def raw_quiet?(session, window_s, now_ns)
        session.raw_paths.values.all? do |path|
          stat = Record::FS.lstat(path)
          stat.nil? || mtime_ns(stat) < now_ns - (window_s * NS)
        end
      end

      def transcripts_final?(context, session)
        dir = Record::Scope.transcripts_dir(session.root, session.key)
        return false if session.natives.empty?

        session.natives.all? do |agent, native|
          name = context.cursor.rendered(session.key, agent)
          current = Deriver::Cursor.stat(native["path"])
          next false unless name.is_a?(String) && current && Record::FS.lstat(File.join(dir, name))&.file?

          session.of("transcript").any? do |record|
            record["agent_key"] == agent && record["body"]["native_inode"] == current["inode"] &&
              record["body"]["native_size"] == current["size"]
          end
        end
      end

      def usage(context, result)
        session = result.session
        native = parsed(context, session)
        recorded = recorded(session)
        result.requests = native.size
        result.counters = sums(native.values)
        result.detail = { "native_requests" => native.size, "recorded_requests" => recorded.size }
        return "usage_mismatch" unless native.keys.sort == recorded.keys.sort
        return "usage_mismatch" unless sums(recorded.values) == result.counters

        nil
      end

      def parsed(context, session)
        reader = context.seam(:ingest_claude)
        requests = {}
        session.natives.keys.sort.each do |agent|
          batch = reader.read(session.natives[agent]["path"], session_id: session.session_id, agent_key: agent)
          batch.usage.each do |entry|
            next unless entry["request_key"].is_a?(String)

            requests[[entry["harness"] || CLAUDE, entry["request_key"]]] = entry.slice(*Record::Kinds::COUNTERS)
          end
        end
        requests
      end

      def recorded(session)
        records = session.of("usage")
        superseded = records.filter_map { |record| record["supersedes"] }.to_h { |id| [id, true] }
        records.reject { |record| superseded[record["id"]] }.each_with_object({}) do |record, out|
          body = record["body"]
          out[[body["harness"], body["request_key"]]] = body.slice(*Record::Kinds::COUNTERS)
        end
      end

      def sums(entries)
        Record::Kinds::COUNTERS.to_h { |counter| [counter, entries.sum { |entry| entry[counter].is_a?(Integer) ? entry[counter] : 0 }] }
      end
    end
  end
end
