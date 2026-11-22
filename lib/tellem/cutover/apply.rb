# frozen_string_literal: true

require "json"
require_relative "../errors"
require_relative "../record/fs"
require_relative "../reports/refresh"
require_relative "../reports/scopes"
require_relative "../deriver/emit"
require_relative "../parity/report"
require_relative "history"
require_relative "plan"

module Tellem
  module Cutover
    APPLIED = "applied"
    ROLLED_BACK = "rolled_back"
    STATE_FILE = "state.json"
    LOCK_FLAGS = File::RDWR | File::CREAT | File::NOFOLLOW
    SPOOL_MODE = 0o700

    module_function

    def apply(plan_id)
      exclusive do
        stored = load(plan_id)
        state = state(plan_id)
        raise OperationalFailure.new("cutover plan #{plan_id} is already applied", next_command: "tellem cutover rollback --confirm #{plan_id}") if state && state["direction"] == APPLIED

        Settings.require_declared(stored["settings"])
        open_items = unresolved(stored).map { |item| item["file"] }
        unless open_items.empty?
          raise OperationalFailure.new("cutover plan #{plan_id} leaves files without an edit or a reason: #{open_items.join(', ')}",
                                       next_command: "edit those files by hand, then tellem cutover plan",
                                       detail: { "cause" => "unresolved_dispositions", "unresolved" => open_items })
        end
        drifted(stored, "before_sha256", "since planning", "tellem cutover plan")
        fresh = propose(otel: stored["otel"] == true, request: stored["request"])
        unless fresh["plan_id"] == plan_id
          cause = fresh["discovery_digest"] == stored["discovery_digest"] ? "plan_changed" : "discovery_changed"
          raise OperationalFailure.new("the host changed since planning (#{cause}); the plan now has id #{fresh['plan_id']}", next_command: "tellem cutover plan",
                                                                                                                       detail: { "cause" => cause })
        end
        parity!(stored["parity_gate"])
        stamp = Record::FS.rfc3339.delete(":")
        index = backup_all(plan_id, "apply-#{stamp}", fresh["files"].map { |file| [file["path"], file["before"], file["mode"]] })
        prepare_spool(stored)
        fresh["files"].each { |file| Files.write(file["path"], file["after"], file["mode"]) }
        priors = Settings.priors(stored["settings"])
        record_levels(plan_id, stored)
        Settings.apply(stored["settings"])
        result = record_state(plan_id, stored, APPLIED, "apply-#{stamp}", index, priors)
        purge_now(stored)
        History.wanted?(stored) ? result.merge("import" => History.start(plan_id)) : result
      end
    end

    def prepare_spool(stored)
      spool = stored.dig("env", "spool")
      return unless spool

      stat = Record::FS.lstat(spool)
      if stat && (stat.symlink? || !stat.directory?)
        raise OperationalFailure.new("the body spool #{spool} is not a directory", next_command: "move it aside, then tellem cutover plan", detail: { "cause" => "spool_not_a_directory" })
      end

      Record::FS.mkdir_p(File.dirname(spool))
      Dir.mkdir(spool, SPOOL_MODE) unless stat
      File.chmod(SPOOL_MODE, spool)
    end

    def record_levels(plan_id, stored)
      Hash(stored["levels"]).each do |name, level|
        env = name == "claude" ? stored["env"] : nil
        Authority::State.applied(plan_id, name, level: level, prior: Authority::State.level(name), env: env ? env["keys"] : {},
                                                settings_path: env && env["settings_path"])
      end
    end

    def purge_now(stored)
      return unless stored["settings"].any? { |item| item["key"] == "retention.purge" }

      Reports::Refresh.run(Reports::Scopes.resolve(all: true))
    end

    def rollback(plan_id)
      exclusive do
        stored = load(plan_id)
        state = state(plan_id)
        raise OperationalFailure.new("cutover plan #{plan_id} is not applied", next_command: "tellem cutover apply --confirm #{plan_id}") unless state && state["direction"] == APPLIED

        source = File.join(dir(plan_id), "backup", state["backup"])
        settled = settings_drift(plan_id, stored, source, state)
        drifted_since_apply(plan_id, stored, settled)
        restored = stored["files"].reject { |file| settled.key?(file["path"]) }.map { |file| [file, original(source, state["index"], file)] }
        stamp = Record::FS.rfc3339.delete(":")
        index = backup_all(plan_id, "rollback-#{stamp}", stored["files"].map { |file| [file["path"], Files.current(file["path"]).first, file["mode"]] })
        restored.each do |file, entry|
          if entry.nil?
            Files.remove(file["path"])
          else
            Files.write(file["path"], entry[:bytes], entry[:mode])
          end
        end
        settled.each { |path, item| Files.write(path, item[:bytes], item[:mode]) }
        Settings.restore(state["priors"])
        Authority::State.rolled_back(plan_id)
        release_spool(stored)
        done = record_state(plan_id, stored, ROLLED_BACK, "rollback-#{stamp}", index, state["priors"]).merge(
          "settings_kept" => settled.map { |path, item| { "path" => path, "undone" => item[:undone], "kept" => item[:kept] } }
        )
        History.wanted?(stored) ? done.merge("import" => History.status(plan_id), "imported_records_kept" => true) : done
      end
    end

    def release_spool(stored)
      spool = stored.dig("env", "spool")
      Dir.rmdir(spool) if spool
    rescue SystemCallError
      nil
    end

    def settings_drift(plan_id, stored, source, state)
      stored["files"].each_with_object({}) do |file, found|
        next unless file["roles"].to_a == ["claude_settings"]

        bytes, mode = Files.current(file["path"])
        sha = Files.sha256(bytes)
        next if bytes.nil? || sha == file["after_sha256"] || sha == Authority::State.restored_sha(plan_id, file["path"])

        digests = stored["env_undo"].to_h
        next if digests.empty?

        updated, undone, kept = Edits.remove_env(bytes, digests)
        prior = original(source, state["index"], file)
        updated = prior[:bytes] if prior && JSON.parse(updated) == JSON.parse(prior[:bytes])
        found[file["path"]] = { bytes: updated, mode: prior ? prior[:mode] : mode || file["mode"], undone: undone, kept: kept }
      rescue JSON::ParserError
        next
      end
    end

    def drifted_since_apply(plan_id, stored, settled = {})
      changed = stored["files"].reject do |file|
        next true if settled.key?(file["path"])

        sha = Files.sha256(Files.current(file["path"]).first)
        sha == file["after_sha256"] || sha == Authority::State.restored_sha(plan_id, file["path"])
      end.map { |file| file["path"] }
      return if changed.empty?

      raise OperationalFailure.new("planned files changed since apply: #{changed.join(', ')}", next_command: "restore the file or review it by hand",
                                                                                                detail: { "cause" => "files_changed", "changed" => changed })
    end

    def drifted(stored, field, since, next_command)
      changed = stored["files"].reject { |file| Files.sha256(Files.current(file["path"]).first) == file[field] }.map { |file| file["path"] }
      return if changed.empty?

      raise OperationalFailure.new("planned files changed #{since}: #{changed.join(', ')}", next_command: next_command,
                                                                                         detail: { "cause" => "files_changed", "changed" => changed })
    end

    def original(source, index, file)
      return nil if file["before_sha256"].nil?

      record = Array(index).find { |item| item["path"] == file["path"] }
      raise OperationalFailure.new("no backup of #{file['path']} in #{source}") unless record

      bytes = Record::FS.read(File.join(source, record["backup"])).b
      raise OperationalFailure.new("the backup of #{file['path']} does not match the plan") unless Files.sha256(bytes) == file["before_sha256"]

      { bytes: bytes, mode: record["mode"] }
    end

    def parity!(gate = "required")
      return if gate.nil?

      scopes = Reports::Scopes.resolve(all: true)
      Reports::Refresh.run(scopes)
      criteria = Tellem::Parity.run(scopes)["criteria"]
      return if criteria["met"]
      return if gate == "when_compared" && criteria["claude"]["considered"].zero? && criteria["codex"]["considered"].zero?

      raise OperationalFailure.new("parity criteria are unmet (claude #{criteria['claude']['passing']}/#{criteria['claude']['considered']}, " \
                                   "codex #{criteria['codex']['passing']}/#{criteria['codex']['considered']})",
                                   next_command: "tellem parity --all", detail: criteria.merge("cause" => "parity_unmet"))
    end

    def backup_all(plan_id, name, entries)
      target = File.join(dir(plan_id), "backup", name)
      Record::FS.mkdir_p(target)
      entries.each_with_index.filter_map do |(path, bytes, mode), position|
        Files.backup(target, position + 1, path, bytes, mode) unless bytes.nil?
      end
    end

    def record_state(plan_id, stored, direction, backup, index, priors)
      state = { "plan_id" => plan_id, "direction" => direction, "at" => Record::FS.rfc3339, "backup" => backup,
                "index" => index, "priors" => priors }
      Record::FS.replace(File.join(dir(plan_id), STATE_FILE), "#{JSON.pretty_generate(state)}\n")
      Deriver::Emit.emit("tellem.cutover.applied", { "plan_id" => plan_id, "files_changed" => stored["files"].size, "direction" => direction })
      summary(stored, state)
    end

    def summary(stored, state)
      inside = stored["files"].select { |file| file["inside_ai_home"] }.map { |file| file["rel"] }
      message = state["direction"] == APPLIED ? "Cut over to tellem (plan #{stored['plan_id']})" : "Roll back the tellem cutover (plan #{stored['plan_id']})"
      git = inside.empty? ? [] : [git_command(stored["ai_home"], "add", inside), git_command(stored["ai_home"], "commit", inside, message)]
      state.merge("files" => stored["files"].map { |file| file.slice("path", "action", "changes") },
                  "settings" => stored["settings"], "backup_dir" => File.join(dir(stored["plan_id"]), "backup", state["backup"]),
                  "git_commands" => git)
    end

    def git_command(ai_home, verb, paths, message = nil)
      words = ["git", "-C", ai_home, verb]
      words += ["-m", message] if message
      (words + ["--"] + paths).map { |word| shell(word) }.join(" ")
    end

    def shell(word)
      word.match?(%r{\A[A-Za-z0-9_./:=@+-]+\z}) ? word : "'#{word.gsub("'", "'\\\\''")}'"
    end

    def state(plan_id)
      JSON.parse(Record::FS.read(File.join(dir(plan_id), STATE_FILE)))
    rescue Errno::ENOENT, Errno::ENOTDIR, JSON::ParserError
      nil
    end

    def latest_applied
      root = Ports::HarnessPaths.cutover_dir
      Dir.children(root).select { |name| PLAN_ID.match?(name) }.filter_map { |name| state(name) }
         .select { |item| item["direction"] == APPLIED }.max_by { |item| item["at"].to_s }
    rescue SystemCallError
      nil
    end

    def exclusive
      Record::FS.mkdir_p(Ports::HarnessPaths.cutover_dir)
      File.open(File.join(Ports::HarnessPaths.cutover_dir, "cutover.lock"), LOCK_FLAGS, Record::Schemas::FILE_MODE) do |lock|
        raise Busy.new("another cutover apply or rollback is running", next_command: "tellem cutover plan") unless lock.flock(File::LOCK_EX | File::LOCK_NB)

        yield
      end
    end

    def result_text(result)
      lines = ["#{result['direction'] == APPLIED ? 'applied' : 'rolled back'} cutover plan #{result['plan_id']}; backups in #{result['backup_dir']}"]
      result["files"].each { |file| lines << "  #{file['action']} #{file['path']}" }
      result["settings"].each { |item| lines << "  #{result['direction'] == APPLIED ? 'set' : 'restored'} #{item['key']}" }
      unless result["git_commands"].empty?
        lines << "tellem does not commit in ~/.ai; review and run:"
        result["git_commands"].each { |command| lines << "  #{command}" }
      end
      lines << "native transcripts and rollouts already purged stay gone; their receipts name each file" if result["direction"] == ROLLED_BACK
      if result["imported_records_kept"]
        job = result["import"]
        lines << "imported records stay in the tellem record: rollback does not remove what the history import added#{job ? " (#{job['sessions_imported'].to_i} sessions, #{job['observations_added'].to_i} observations)" : ''}, and a running import stops before its next scope"
      elsif result["import"]
        lines << "history import started in the background; tellem cutover status shows its progress and result, and a failed import does not undo this plan"
      end
      Array(result["settings_kept"]).each do |item|
        lines << "#{item['path']} changed after apply, so only this plan's env keys were undone (#{item['undone'].empty? ? 'none left' : item['undone'].join(', ')}); other changes stayed#{item['kept'].empty? ? '' : ", and #{item['kept'].join(', ')} held another value and stayed"}"
      end
      lines.join("\n")
    end
  end
end
