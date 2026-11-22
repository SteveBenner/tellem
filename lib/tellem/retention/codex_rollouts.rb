# frozen_string_literal: true

require "json"
require "open3"
require_relative "../authority/switch"
require_relative "../ids"
require_relative "../parity/rollout"
require_relative "../ports/harness_paths"
require_relative "../projections/tokens"
require_relative "../record/fs"
require_relative "../record/reader"
require_relative "../deriver/session"
require_relative "../deriver/sources"
require_relative "check"
require_relative "remove"
require_relative "tool_counts"

module Tellem
  module Retention
    module CodexRollouts
      CODEX = "codex"
      DELETE_TIMEOUT_S = 30
      UUID = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/.freeze
      COMPRESSED = "rollout-*-%<id>s.jsonl.zst"
      END_EVENTS = %w[task_complete turn_complete].freeze
      SETTLE_NS = Deriver::Session::SETTLE_S * Check::NS
      FAILED = "codex_delete_failed"

      module_function

      def evaluate(context, key, window_s, session: nil, now_ns: Record::FS.now_ns)
        _harness, session_id = key.split("-", 2)
        main = context.cursor.natives(key).dig(Ids::MAIN_AGENT, "path")
        return held_only(context, key, "rollout_unreadable", session) if compressed?(session_id)
        return Check::Result.new(session_key: key, state: "gone") unless main.is_a?(String) && Record::FS.lexists?(main)

        stat = Record::FS.lstat(main)
        return held_only(context, key, stat.symlink? ? "symlink" : "not_regular", session) unless stat.file?

        mtime = Check.mtime_ns(stat)
        result = Check::Result.new(session_key: key, files: [{ "path" => main, "inode" => stat.ino, "size" => stat.size, "mtime_ns" => mtime }], dirs: [], newest_ns: mtime)
        window = window_s.respond_to?(:call) ? window_s.call(mtime) : window_s
        return Check.waiting(result, "older_than_plan") if window.nil?
        return Check.waiting(result, "window") if mtime >= now_ns - [window * Check::NS, SETTLE_NS].max

        result.session, unreadable = session ? [session, nil] : load(context, key, session_id, main)
        condition = unreadable || conditions(context, result, main)
        return Check.waiting(result, condition) if window.zero? && Check::FINAL_WAIT.include?(condition)

        result.state = condition ? "held" : "candidate"
        result.condition = condition
        result
      end

      def held_only(context, key, condition, session)
        Check::Result.new(session_key: key, state: "held", condition: condition, session: session || Deriver::Session.new(context, key))
      end

      def load(context, key, session_id, main)
        session = Deriver::Session.new(context, key)
        Deriver::Sources.load_raw(session)
        session.natives.merge!(Deriver::Sources.discover(context, CODEX, session_id, main))
        [session, nil]
      rescue Deriver::Sources::HarnessUnreadable
        [session, Deriver::Sources::UNREADABLE]
      end

      def compressed?(session_id)
        pattern = format(COMPRESSED, id: session_id)
        !Dir.glob(File.join(Ports::HarnessPaths.codex_sessions, "*", "*", "*", pattern)).empty?
      end

      def conditions(context, result, main)
        session = result.session
        reference = reference(main)
        return "rollout_unreadable" unless reference
        return "not_final" unless rollout_final?(main)
        return "unsettled" if session.unsettled || context.cursor.session(session.key)["unsettled"] == true
        return "transcript_not_final" unless Check.transcripts_final?(context, session)

        usage(session, reference, result) || ToolCounts.condition(context, result)
      end

      def reference(main)
        Parity::Rollout.reference(main)
      rescue SystemCallError, SymlinkRefused, JSON::ParserError, EncodingError
        nil
      end

      def rollout_final?(main)
        last = nil
        Record::Reader.each(main) do |entry|
          payload = entry["payload"]
          last = payload["type"] if entry["type"] == "event_msg" && payload.is_a?(Hash)
        end
        END_EVENTS.include?(last)
      rescue SystemCallError, SymlinkRefused
        false
      end

      def usage(session, reference, result)
        rows = Projections::Tokens.rows(session.root).select { |row| row["session_id"] == session.session_id }
        verdict = Parity::Rollout.tokens(rows, reference)
        result.requests = reference["requests"].size
        result.counters = verdict["sums"].transform_values { |pair| pair["rollout"] }
        result.detail = { "rollout_requests" => verdict["rows"]["rollout"], "recorded_requests" => verdict["rows"]["tellem"] }
        verdict["verdict"] == "match" ? nil : "usage_mismatch"
      end

      def remove(context, result, window_days)
        return "authority_stopped" if Authority::Switch.off?

        hashed = result.files.map { |file| file.merge(Remove.digest(file["path"])) }
        return "changed_during_removal" if result.files.any? { |file| Remove.moved?(file) }

        receipt = Remove.pending(context, result, hashed, window_days, method: "codex_delete")
        ok = delete(result.session_key.split("-", 2).last)
        close(context, receipt, ok)
        return FAILED unless ok

        hashed.any? { |file| Record::FS.lexists?(file["path"]) } ? "#{FAILED}_file_remained" : nil
      end

      def close(context, receipt, success)
        Remove.close_codex(context, receipt, success)
      end

      def delete(session_id)
        return false unless UUID.match?(session_id)

        Open3.popen2e("codex", "delete", "--force", session_id, pgroup: true) do |stdin, stdout, wait|
          stdin.close
          reader = Thread.new { stdout.read.to_s }
          unless wait.join(DELETE_TIMEOUT_S)
            Process.kill("KILL", -wait.pid)
            reader.kill
            return false
          end
          reader.value
          wait.value.success?
        end
      rescue SystemCallError, IOError
        false
      end
    end
  end
end
