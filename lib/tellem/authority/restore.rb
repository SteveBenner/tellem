# frozen_string_literal: true

require "digest"
require_relative "../config/resolver"
require_relative "../cutover/builder"
require_relative "../cutover/edits"
require_relative "../cutover/files"
require_relative "../deriver/emit"
require_relative "../errors"
require_relative "../ports/harness_paths"
require_relative "../record/fs"
require_relative "../record/schemas"
require_relative "state"
require_relative "switch"

module Tellem
  module Authority
    module Restore
      LOCK_FLAGS = File::RDWR | File::CREAT | File::NOFOLLOW
      STOP = "stop_switch"
      EVENT = "tellem.authority.lowered"
      FAILED = "restore_failed"
      FAILED_EVENT = "tellem.authority.restore_failed"
      BUSY = "lock_busy"
      MISSING = %w[Errno::ENOENT Errno::ENOTDIR].freeze
      COMMAND = "tellem authority restore"

      module_function

      def lost(kind, reason, session_key: nil)
        attempt("claude", kind, reason, session_key)
      end

      def stop(reason)
        State::HARNESSES.filter_map { |name| attempt(name, STOP, reason, nil) }
      end

      def retry_failed
        State.restore_failures.keys.filter_map { |name| attempt(name, nil, nil, nil) }
      end

      def failed?(outcome)
        outcome.is_a?(Hash) && outcome[FAILED] == true
      end

      def fix(failure)
        file = failure["file"].to_s
        return "wait for the cutover plan, apply, or rollback that holds #{file}" if failure["error"] == BUSY
        return "put #{File.dirname(file)} back" if MISSING.include?(failure["error"])

        "make #{file} and #{File.dirname(file)} writable"
      end

      def attempt(name, kind, reason, session_key)
        pending = State.restore_failure(name)
        kind, reason, session_key = pending.values_at("kind", "reason", "session_key") if pending
        outcome = locked { lower(name, kind, reason, session_key) }
        return failure(name, kind, reason, session_key, BUSY, "another cutover plan, apply, or rollback holds the lock", lock_path) if outcome == :busy

        State.restore_cleared(name) if outcome.nil? && pending
        outcome
      rescue StandardError => e
        file = (State.harness(name) || {})["settings_path"]
        failure(name, kind, reason, session_key, e.class.name, e.message[0, 200], file.is_a?(String) ? file : State.file)
      end

      def failure(name, kind, reason, session_key, error, message, file)
        recorded = State.restore_failed(name, { "harness" => name, "kind" => kind, "reason" => reason, "session_key" => session_key,
                                                "error" => error, "message" => message, "file" => file }.compact)
        if recorded["attempts"] == 1
          Deriver::Emit.emit(FAILED_EVENT, recorded.slice("kind", "harness", "reason", "session_key", "error"))
        end
        recorded.merge(FAILED => true)
      end

      def lock_path
        File.join(Ports::HarnessPaths.cutover_dir, "cutover.lock")
      end

      def locked
        Record::FS.mkdir_p(Ports::HarnessPaths.cutover_dir)
        File.open(lock_path, LOCK_FLAGS, Record::Schemas::FILE_MODE) do |lock|
          return :busy unless lock.flock(File::LOCK_EX | File::LOCK_NB)

          yield
        end
      end

      def lower(name, kind, reason, session_key)
        from = State.level(name)
        return nil if from == State::OBSERVE

        entry = State.harness(name) || {}
        recovered = entry["restore_failed"].is_a?(Hash) ? entry["restore_failed"].slice("first_at", "attempts", "error") : nil
        to = entry["prior"].is_a?(String) ? entry["prior"] : State::OBSERVE
        edit = settings_edit(entry)
        Config.set("authority.#{name}", to)
        State.lowered(name, kind: kind, reason: reason, session_key: session_key, from: from, to: to, restored: edit && edit[:restored])
        record = { "kind" => kind, "harness" => name, "reason" => reason, "session_key" => session_key, "from" => from, "to" => to,
                   "plan_id" => entry["plan_id"], "env_removed" => edit ? edit[:removed] : [], "env_kept" => edit ? edit[:kept] : [],
                   "backup" => edit && edit[:backup], "recovered_from" => recovered }.compact
        State.receipt(record)
        Deriver::Emit.emit(EVENT, record.slice("kind", "harness", "reason", "session_key", "from", "to", "plan_id"))
        record
      end

      def settings_edit(entry)
        path = entry["settings_path"]
        env = entry["env"]
        return nil unless path.is_a?(String) && env.is_a?(Hash) && !env.empty?

        real = File.join(File.realpath(File.dirname(path)), File.basename(path))
        stat = Record::FS.lstat(real)
        return nil unless stat
        raise OperationalFailure.new("#{real} is not a regular file, so the env keys could not be removed") unless stat.file?

        build = Cutover::Builder.new(nil)
        removed = []
        kept = []
        build.edit(real, "authority_restore", outside: real) do |text|
          updated, gone, left = Cutover::Edits.remove_env(text, env)
          removed = gone
          kept = left
          [updated, gone.map { |key| "remove env #{key}" }]
        end
        file = build.entries.first
        return { removed: [], kept: kept, restored: nil, backup: nil } unless file

        stamp = Record::FS.rfc3339.delete(":")
        backup = State.backup_dir(stamp)
        Cutover::Files.backup(backup, 1, file["path"], file["before"], file["mode"])
        Cutover::Files.write(file["path"], file["after"], file["mode"])
        { removed: removed, kept: kept, restored: { file["path"] => file["after_sha256"] }, backup: backup }
      end
    end
  end
end
