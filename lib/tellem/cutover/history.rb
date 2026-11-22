# frozen_string_literal: true

require "json"
require "rbconfig"
require "time"
require_relative "../errors"
require_relative "../deriver/emit"
require_relative "../import/plan"
require_relative "../ports/harness_paths"
require_relative "../record/fs"
require_relative "../record/schemas"
require_relative "../reports/scopes"

module Tellem
  module Cutover
    module History
      FILE = "import.json"
      LOCK = "import.lock"
      LOCK_FLAGS = File::RDWR | File::CREAT | File::NOFOLLOW
      SUBSUME = "subsume"
      SOURCES = %w[native specstory ledger].freeze
      STARTING = "starting"
      RUNNING = "running"
      DONE = "done"
      FAILED = "failed"
      INTERRUPTED = "interrupted"
      STOPPED = "stopped_by_rollback"
      NOT_STARTED = "not_started"
      UNFINISHED = [FAILED, INTERRUPTED, NOT_STARTED].freeze
      STARTING_GRACE_S = 60
      SAMPLE = 5
      EVENT = "tellem.import.applied"

      module_function

      def wanted?(stored)
        stored.dig("request", "specstory") == SUBSUME
      end

      def resume_command(plan_id)
        "tellem cutover import --confirm #{plan_id}"
      end

      def file(plan_id)
        File.join(Cutover.dir(plan_id), FILE)
      end

      def lock_file(plan_id)
        File.join(Cutover.dir(plan_id), LOCK)
      end

      def read(plan_id)
        data = JSON.parse(Record::FS.read(file(plan_id)))
        data.is_a?(Hash) ? data : nil
      rescue Errno::ENOENT, Errno::ENOTDIR, JSON::ParserError
        nil
      end

      def save(plan_id, job)
        Record::FS.replace(file(plan_id), "#{JSON.pretty_generate(job.merge('updated_at' => Record::FS.rfc3339))}\n")
        job
      end

      def start(plan_id)
        job = fresh(plan_id).merge("state" => STARTING)
        save(plan_id, job)
        pid = Process.spawn(RbConfig.ruby, File.join(Tellem.root, "bin", "tellem"), "cutover", "import", "--confirm", plan_id,
                            pgroup: true, in: :close, out: File::NULL, err: File::NULL)
        Process.detach(pid)
        save(plan_id, job.merge("pid" => pid))
      rescue SystemCallError => e
        save(plan_id, job.merge("state" => FAILED, "failures" => [{ "source" => "start", "error" => e.class.name, "message" => e.message[0, 200] }]))
      end

      def fresh(plan_id)
        { "plan_id" => plan_id, "state" => NOT_STARTED, "started_at" => Record::FS.rfc3339, "sources" => {}, "done" => {}, "failures" => [],
          "sessions_imported" => 0, "observations_added" => 0, "gaps_added" => 0, "sources_changed" => 0, "attempts" => 0 }
      end

      def run(plan_id)
        stored = Cutover.load(plan_id)
        refuse(plan_id) unless wanted?(stored) && applied?(plan_id)

        File.open(lock_file(plan_id), LOCK_FLAGS, Record::Schemas::FILE_MODE) do |lock|
          return status(plan_id) unless lock.flock(File::LOCK_EX | File::LOCK_NB)

          work(plan_id)
        end
      end

      def refuse(plan_id)
        raise OperationalFailure.new("cutover plan #{plan_id} is not an applied --specstory subsume plan, so it has no history import", next_command: "tellem cutover status")
      end

      def work(plan_id)
        job = read(plan_id) || fresh(plan_id)
        job.merge!("state" => RUNNING, "pid" => Process.pid, "attempts" => job["attempts"].to_i + 1, "failures" => [])
        job.delete("finished_at")
        save(plan_id, job)
        SOURCES.each { |source| step(plan_id, job, source) }
        job["compressed_rollouts"] = compressed_rollouts
        job["state"] = job["state"] == STOPPED ? STOPPED : (job["failures"].empty? ? DONE : FAILED)
        job["finished_at"] = Record::FS.rfc3339
        save(plan_id, job)
        Deriver::Emit.emit(EVENT, job.slice("plan_id", "state", "sessions_imported", "observations_added"))
        job
      end

      def step(plan_id, job, source)
        return if job["state"] == STOPPED

        paths = source_paths(source)
        if source != "native" && paths.empty?
          job["sources"][source] = { "sessions" => 0, "to_import" => 0, "skipped" => 0, "scopes" => 0, "files" => 0 }
          return save(plan_id, job)
        end

        plan, candidates = Tellem::Import.build([source], paths)
        chosen = candidates.select { |candidate| Tellem::Import.decision(plan, candidate)["action"] == Tellem::Import::IMPORT }
        groups = chosen.group_by(&:home_root).sort
        job["sources"][source] = { "sessions" => plan["sessions"].size, "to_import" => chosen.size, "skipped" => plan["skipped"].size,
                                   "scopes" => groups.size, "files" => plan["files"].size }
        save(plan_id, job)
        groups.each { |root, list| scope(plan_id, job, source, root, list) }
        verify(plan_id, job, plan)
      rescue StandardError => e
        failed(plan_id, job, source, nil, e)
      end

      def source_paths(source)
        return [] if source == "native"

        roots = Reports::Scopes.resolve(all: true).reject { |item| item["gone"] }.map { |item| item["root"] }
        if source == "specstory"
          roots.select { |root| File.directory?(File.join(root, Tellem::Import::SpecStory::HISTORY)) }
        else
          roots.map { |root| File.join(root, Tellem::Import::Ledger::FILE) }.select { |path| Tellem::Import::Files.regular?(path) }
        end
      end

      def scope(plan_id, job, source, root, list)
        key = "#{source}:#{root}"
        return if job["state"] == STOPPED || job["done"].key?(key)
        return save(plan_id, job.merge!("state" => STOPPED)) unless applied?(plan_id)

        result = Tellem::Import.apply_scope(root, list)
        job["done"][key] = { "sessions" => list.size, "observations_added" => result["observations_added"], "gaps_added" => result["gaps_added"], "errors" => result["errors"].size }
        job["sessions_imported"] += list.size
        job["observations_added"] += result["observations_added"].to_i
        job["gaps_added"] += result["gaps_added"].to_i
        save(plan_id, job)
      rescue StandardError => e
        failed(plan_id, job, source, root, e)
      end

      def verify(plan_id, job, plan)
        Tellem::Import.verify(plan)
      rescue OperationalFailure => e
        changed = Array(e.detail && e.detail["changed"])
        job["sources_changed"] += changed.size
        job["sources_changed_sample"] = (Array(job["sources_changed_sample"]) + changed).first(SAMPLE)
        save(plan_id, job)
      end

      def failed(plan_id, job, source, root, error)
        job["failures"] << { "source" => source, "root" => root, "error" => error.class.name, "message" => error.message[0, 200] }.compact
        save(plan_id, job)
      end

      def compressed_rollouts
        Dir.glob(File.join(Ports::HarnessPaths.codex_sessions, "*", "*", "*", "rollout-*.jsonl.zst")).size
      end

      def applied?(plan_id)
        Cutover.state(plan_id)&.fetch("direction", nil) == APPLIED
      end

      def status(plan_id)
        job = read(plan_id)
        return nil unless job

        job.merge("state" => observed(plan_id, job))
      end

      def observed(plan_id, job)
        state = job["state"]
        return state unless [STARTING, RUNNING].include?(state)
        return state if held?(plan_id)
        return state if state == STARTING && Time.now - Time.iso8601(job["started_at"].to_s) < STARTING_GRACE_S

        INTERRUPTED
      rescue ArgumentError
        INTERRUPTED
      end

      def held?(plan_id)
        File.open(lock_file(plan_id), File::RDONLY | File::NOFOLLOW) do |lock|
          free = lock.flock(File::LOCK_EX | File::LOCK_NB)
          lock.flock(File::LOCK_UN) if free
          !free
        end
      rescue Errno::ENOENT, Errno::ENOTDIR
        false
      end

      def current
        applied = Cutover.latest_applied
        if applied && wanted?(Cutover.load(applied["plan_id"]))
          id = applied["plan_id"]
          return status(id) || fresh(id).reject { |key, _value| key == "started_at" }
        end
        latest
      end

      def latest
        root = Ports::HarnessPaths.cutover_dir
        Dir.children(root).select { |name| PLAN_ID.match?(name) }.filter_map { |name| status(name) }.max_by { |job| job["started_at"].to_s }
      rescue Errno::ENOENT
        nil
      rescue SystemCallError => e
        { "state" => FAILED, "failures" => [{ "source" => "status", "error" => e.class.name, "message" => e.message[0, 200] }] }
      end

      def text(job)
        lines = ["history import #{job['state']}#{job['plan_id'] ? " (plan #{job['plan_id']})" : ''}: " \
                 "#{job['sessions_imported'].to_i} sessions imported, #{job['observations_added'].to_i} observations, #{job['gaps_added'].to_i} gaps"]
        Hash(job["sources"]).each do |source, item|
          lines << "  #{source}: #{item['to_import']} of #{item['sessions']} sessions to import, #{item['scopes']} scopes, #{item['skipped']} skipped, #{item['files']} files hashed"
        end
        lines << "  #{job['done'].size} scopes finished" unless job["done"].to_h.empty?
        Array(job["failures"]).each { |item| lines << "  failed #{item['source']}#{item['root'] ? " #{item['root']}" : ''}: #{item['error']}: #{item['message']}" }
        lines << "  #{job['sources_changed']} source files changed during the import; a running session appends to its own" if job["sources_changed"].to_i.positive?
        lines << "  #{job['compressed_rollouts']} compressed Codex rollouts cannot be read and were not imported" if job["compressed_rollouts"].to_i.positive?
        lines << "next: #{resume_command(job['plan_id'])}" if job["plan_id"] && UNFINISHED.include?(job["state"])
        lines.join("\n")
      end
    end
  end
end
