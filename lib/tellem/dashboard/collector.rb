# frozen_string_literal: true

require "etc"
require "json"
require "time"
require_relative "../errors"
require_relative "../ids"
require_relative "../record/fs"
require_relative "../record/scope"
require_relative "../reports/agent_time"
require_relative "../reports/agents"
require_relative "../reports/health"
require_relative "../reports/records"
require_relative "../reports/scan"
require_relative "../reports/scopes"
require_relative "../reports/sessions_brief"
require_relative "../reports/tokens"

module Tellem
  module Dashboard
    module Collector
      HOURS = 720
      HOUR = 3600
      INSTANT = "%Y-%m-%dT%H:%M:%SZ"
      BOUND = "%Y-%m-%dT%H:%M:%S.000Z"
      DIMENSIONS = "agent,session,model,effort,persona,subagent_type"
      WINDOW_STARTS = [HOURS - 24, HOURS - 168, 0].freeze
      LAG_LIMIT_SECONDS = 900
      UNDATED = "1970-01-01T00:00:00"

      Job = Struct.new(:index, :scope, :key, :derived, :raw, :bytes, keyword_init: true)

      Window = Struct.new(:as_of, :since, keyword_init: true) do
        def from
          @from ||= since.strftime(BOUND)
        end

        def to
          @to ||= as_of.strftime(BOUND)
        end

        def before_end?(record)
          record["ts"].to_s < to
        end

        def holds?(ts)
          ts.is_a?(String) && ts >= from && ts < to
        end

        def hour(ts)
          return hour_of(ts) unless ts.end_with?("Z")

          (@hours ||= {})[ts[0, 13]] ||= hour_of(ts)
        end

        def hour_of(ts)
          (Time.iso8601(ts).to_i - since.to_i) / HOUR
        end
      end

      Result = Struct.new(:window, :scopes, :gone, :unreadable, :repos, :files, :usage, :columns, :owners, :hook_gaps, keyword_init: true)

      module_function

      def run(now: Time.now)
        window = window_at(now)
        all = Reports::Scopes.resolve(all: true)
        scopes = Reports::Scopes.live(all)
        usage, columns, unreadable = usage_rows(scopes, window)
        jobs, raw_present = inventory(scopes, window, wanted(usage, columns), unreadable)
        settings = time_settings(scopes, unreadable)
        files = read(jobs.reject { |job| unreadable.key?(job.scope) }, scopes, settings, window)
        files.each { |file| unreadable[file["scope"]] = file["error"] if file["error"] }
        repos = scopes.each_index.map { |position| repo(scopes[position], position, files, raw_present, unreadable) }
        files = files.reject { |file| unreadable.key?(file["scope"]) }
        Result.new(window: window, scopes: scopes, gone: all.size - scopes.size, unreadable: unreadable, repos: repos, files: files,
                   usage: usage, columns: columns, owners: owners(scopes, files, window), hook_gaps: Reports::Health.hook_gap_hours(since: window.since, before: window.as_of)["rows"])
      end

      def window_at(now)
        as_of = Time.at(now.to_i).utc
        since = Time.at(((as_of.to_i / HOUR) - (HOURS - 1)) * HOUR).utc
        Window.new(as_of: as_of, since: since)
      end

      def usage_rows(scopes, window)
        params = Reports::Tokens.params(by: DIMENSIONS, since: window.since.strftime(INSTANT))
        failed = {}
        begin
          rows, columns = Reports::Tokens.request_rows(scopes, params)
        rescue StandardError
          failed = usage_failures(scopes, params)
          raise if failed.empty?

          rows, columns = Reports::Tokens.request_rows(scopes.reject.with_index { |_scope, position| failed.key?(position) }, params)
        end
        ts = columns.fetch("ts")
        [rows.select { |tuple| window.holds?(tuple[ts]) }, columns, failed]
      end

      def usage_failures(scopes, params)
        scopes.each_with_index.with_object({}) do |(scope, position), failed|
          Reports::Tokens.request_rows([scope], params, workers: 1)
        rescue StandardError => e
          failed[position] = e.class.name
        end
      end

      def wanted(usage, columns)
        session = columns.fetch("session_key")
        usage.each_with_object({}) { |tuple, out| out[tuple[session]] = true }
      end

      def inventory(scopes, window, wanted, unreadable)
        jobs = []
        raw_present = {}
        scopes.each_with_index do |scope, position|
          next if unreadable.key?(position)

          found, present = scope_jobs(scope["root"], position, window.since.to_i, wanted)
          jobs.concat(found)
          raw_present[position] = present
        rescue StandardError => e
          unreadable[position] = e.class.name
        end
        jobs.each_with_index { |job, index| job.index = index }
        [jobs, raw_present]
      end

      def scope_jobs(root, position, since, wanted)
        present = false
        jobs = children(Record::Scope.sessions_dir(root)).select { |key| Ids.valid_session_key?(key) }.filter_map do |key|
          path = Record::Scope.derived_path(root, key)
          stat = Record::FS.lstat(path)
          derived = stat&.file? && (stat.mtime.to_i >= since || wanted.key?(key)) ? path : nil
          recent = []
          bytes = derived ? stat.size : 0
          raw_files(Record::Scope.raw_dir(root, key)).each do |file, info|
            present ||= info.size.positive?
            next if info.mtime.to_i < since

            bytes += info.size
            recent << file
          end
          Job.new(index: 0, scope: position, key: key, derived: derived, raw: recent, bytes: bytes) if derived || !recent.empty?
        end
        [jobs, present]
      end

      def raw_files(dir)
        return [] unless Record::FS.lstat(dir)&.directory?

        children(dir).filter_map do |name|
          next unless name.end_with?(".jsonl")

          file = File.join(dir, name)
          info = Record::FS.lstat(file)
          [file, info] if info&.file?
        end
      end

      def children(dir)
        Dir.children(dir).sort
      rescue Errno::ENOENT, Errno::ENOTDIR
        []
      end

      def time_settings(scopes, unreadable)
        scopes.each_with_index.with_object({}) do |(scope, position), out|
          next if unreadable.key?(position)

          out[position] = Reports::AgentTime.settings(Reports::Records::Data.new(scope: scope))
        rescue StandardError => e
          unreadable[position] = e.class.name
        end
      end

      def read(jobs, scopes, settings, window)
        count = worker_count(jobs)
        pairs = count <= 1 ? inline(jobs, scopes, settings, window) : forked(jobs, count, scopes, settings, window)
        pairs.sort_by(&:first).map(&:last)
      end

      def worker_count(jobs)
        return 1 unless Process.respond_to?(:fork)
        return 1 if jobs.size < 2 || jobs.sum(&:bytes) < Reports::Scan::INLINE_BYTES

        [Etc.nprocessors, Reports::Scan::MAX_WORKERS, jobs.size].min
      end

      def inline(jobs, scopes, settings, window)
        jobs.map { |job| [job.index, JSON.parse(encoded(job, scopes[job.scope], settings[job.scope], window))] }
      end

      def forked(jobs, count, scopes, settings, window)
        loads = Array.new(count, 0)
        shares = Array.new(count) { [] }
        jobs.sort_by { |job| [-job.bytes, job.index] }.each do |job|
          slot = loads.each_with_index.min.last
          shares[slot] << job
          loads[slot] += job.bytes
        end
        spawned = shares.reject(&:empty?).map { |share| spawn(share, scopes, settings, window) }
        spawned.flat_map { |pid, reader| collect(pid, reader) }
      end

      def spawn(share, scopes, settings, window)
        reader, writer = IO.pipe
        reader.binmode
        writer.binmode
        pid = Process.fork do
          reader.close
          status = 1
          begin
            parts = share.map { |job| "[#{job.index},#{encoded(job, scopes[job.scope], settings[job.scope], window)}]".b }
            writer.write("[", parts.join(","), "]")
            status = 0
          ensure
            writer.close
            Process.exit!(status)
          end
        end
        writer.close
        [pid, reader]
      end

      def collect(pid, reader)
        bytes = reader.read
        reader.close
        _, status = Process.wait2(pid)
        unless status.success? && !bytes.empty?
          raise OperationalFailure.new("a dashboard worker failed (#{status.exitstatus.inspect})", next_command: "tellem health")
        end

        JSON.parse(bytes.force_encoding(Encoding::UTF_8))
      end

      def encoded(job, scope, setting, window)
        JSON.generate(read_job(job, scope, setting, window))
      rescue StandardError => e
        JSON.generate({ "scope" => job.scope, "error" => e.class.name })
      end

      def read_job(job, scope, setting, window)
        out = { "scope" => job.scope, "key" => job.key, "session" => nil, "gaps" => [], "superseded_gaps" => [], "torn_derived" => 0 }
        if job.derived
          data = Reports::Records.assemble(scope, [job.derived], session_keys: [job.key], accept: window.method(:before_end?))
          out["torn_derived"] = data.torn
          out["session"] = session(data, job.key, setting, window)
          gaps(data, window, out)
        end
        out.merge!(raw(job.raw, window))
      end

      def gaps(data, window, out)
        data.of_kind("gap").each do |record|
          out["superseded_gaps"] << record["supersedes"] if record["supersedes"]
          next unless window.holds?(record["ts"])

          body = record["body"] || {}
          count = body["count"].is_a?(Integer) ? body["count"] : 1
          out["gaps"] << [record["id"], window.hour(record["ts"]), body["cause"].to_s, body["harness"], count]
        end
      end

      def raw(paths, window)
        torn = 0
        newest = nil
        samples = Hash.new(0)
        paths.each do |path|
          torn += Reports::Records.each_line_record(path) do |record|
            ts = record["ts"]
            next unless ts.is_a?(String) && ts < window.to

            newest = ts if newest.nil? || ts > newest
            next unless record["hook_ms"].is_a?(Integer) && ts >= window.from

            hour = window.hour(ts)
            bucket = WINDOW_STARTS.index { |start| hour >= start }
            samples[[record["harness"].to_s, record["event"].to_s, bucket, record["hook_ms"]]] += 1
          end
        end
        { "torn_raw" => torn, "newest" => newest, "hooks" => samples.map { |key, count| [*key, count] } }
      end

      def session(data, key, setting, window)
        own = data.records.select { |record| record["session_key"] == key }
        recent = own.select { |record| window.holds?(record["ts"]) }
        return nil if recent.empty?

        found = Reports::Agents.session(data, key)
        first, last = own.map { |record| record["ts"] }.reject { |ts| ts.start_with?(UNDATED) }.minmax
        agents, positions = agents(data, key, setting, window)
        calls = recent.select { |record| record["kind"] == "tool_call" }
        main = agents.find { |agent| agent["key"] == Ids::MAIN_AGENT }
        {
          "key" => key,
          "harness" => found["harness"],
          "label" => Reports::SessionsBrief.label(own.select { |record| record["kind"] == "task" }),
          "started" => instant(found["started_at"]),
          "ended" => instant(found["ended_at"]),
          "first" => instant(first),
          "last" => instant(last),
          "open" => main && main["open"],
          "home" => found.dig("home", "real_path"),
          "active_hours" => ranges(recent.map { |record| window.hour(record["ts"]) }),
          "agents" => agents,
          "calls" => call_rows(calls, positions),
          "failures" => failure_rows(calls, positions)
        }
      end

      def instant(ts)
        ts.is_a?(String) ? Time.iso8601(ts).to_i : nil
      end

      def ranges(hours)
        hours.uniq.sort.slice_when { |left, right| right > left + 1 }.map { |run| [run.first, run.last] }
      end

      def agents(data, key, setting, window)
        found = Reports::Agents.agents(data, key)
        mode, idle = setting
        times = found.keys.to_h { |agent| [agent, lifetime(data, key, agent, mode, idle, window.as_of.to_f)] }
        kids = Reports::Agents.children(found)
        list = []
        positions = {}
        visit = lambda do |agent, parent|
          next if positions.key?(agent)

          position = list.size
          positions[agent] = position
          list << agent_row(data, key, found.fetch(agent), parent, times.fetch(agent), setting, window)
          kids.fetch(agent, []).sort_by { |child| order(times, child) }.each { |child| visit.call(child, position) }
        end
        Reports::Agents.roots(found).each { |agent| visit.call(agent, nil) }
        found.keys.sort_by { |agent| order(times, agent) }.each { |agent| visit.call(agent, nil) }
        [list, positions]
      end

      def order(times, agent)
        start = times.fetch(agent)[:start]
        [start ? 0 : 1, start || 0, agent]
      end

      def agent_row(data, key, fields, parent, lifetime, setting, window)
        mode, idle = setting
        agent = fields["agent_key"]
        time = Reports::AgentTime.for(data, key, agent, mode: mode, idle_seconds: idle, now: window.as_of.to_f)
        {
          "key" => agent,
          "parent" => parent,
          "type" => fields["agent_type"],
          "model" => fields["model"],
          "effort" => fields["effort"],
          "isolation" => fields["isolation"],
          "started" => lifetime[:start]&.to_i,
          "ended" => lifetime[:stop]&.to_i,
          "open" => time["open"],
          "wall" => time["wall"],
          "active" => time["active"] || time["active_spans"],
          "waiting" => time["waiting"],
          "spans" => lifetime[:spans].map { |from, to| [from.to_i, to.to_i] }
        }
      end

      def lifetime(data, key, agent, mode, idle, now)
        time = Reports::AgentTime
        records = time.index(data).fetch([key, agent], [])
        life = records.select { |record| record["kind"] == "lifecycle" }.sort_by { |record| Reports::Records.sort_key(record) }
        declared = records.select { |record| record["kind"] == "agent" }.min_by { |record| Reports::Records.sort_key(record) }
        started = life.find { |record| record.dig("body", "state") == "started" } || declared
        start = started && time.epoch(started["ts"])
        stop = life.select { |record| time::FINAL.include?(record.dig("body", "state")) }.filter_map { |record| time.epoch(record["ts"]) }.max
        spans = case time::MODES.include?(mode) ? mode : "spans"
                when "activity" then activity_spans(records, idle)
                else lifecycle_spans(records, life, agent, start, stop, now)
                end
        { start: start, stop: stop, spans: spans }
      end

      def lifecycle_spans(records, life, agent, start, stop, now)
        horizon = [instants(records).max, now].compact.min
        return Reports::AgentTime.main_spans(life, horizon, stop) if agent == Ids::MAIN_AGENT

        finish = stop || horizon
        start && finish ? [[start, [finish, start].max]] : []
      end

      def activity_spans(records, idle)
        instants(records).uniq.sort.slice_when { |from, to| to - from > idle }.filter_map { |run| [run.first, run.last] if run.size > 1 }
      end

      def instants(records)
        records.filter_map do |record|
          Reports::AgentTime.epoch(record["ts"]) if Reports::AgentTime::ACTIVITY_KINDS.include?(record["kind"])
        end
      end

      def call_rows(calls, positions)
        groups = {}
        calls.each do |record|
          body = record["body"] || {}
          group = groups[[positions.fetch(record["agent_key"]), tool_name(body)]] ||= [0, 0, 0, 0]
          group[0] += 1
          group[1] += 1 if body["is_error"] == true
          next unless body["duration_ms"].is_a?(Numeric)

          group[2] += body["duration_ms"]
          group[3] += 1
        end
        groups.keys.sort_by { |agent, tool| [agent, tool.to_s] }.map do |key|
          count, failed, total, timed = groups[key]
          [*key, count, failed, timed.positive? ? total : nil, timed]
        end
      end

      def failure_rows(calls, positions)
        failed = calls.select { |record| record.dig("body", "is_error") == true }
        failed.sort_by { |record| [record["ts"], record["id"]] }.reverse.map do |record|
          body = record["body"]
          duration = body["duration_ms"]
          [instant(record["ts"]), positions.fetch(record["agent_key"]), tool_name(body), duration.is_a?(Numeric) ? duration : nil]
        end
      end

      def tool_name(body)
        body["tool"].is_a?(String) ? body["tool"] : nil
      end

      def repo(scope, position, files, raw_present, unreadable)
        return unread_repo if unreadable.key?(position)

        own = files.select { |file| file["scope"] == position }
        newest = own.filter_map { |file| file["newest"] }.max
        derive = Reports::Health.derive_lag(scope["root"], newest)
        last = instant(derive["last_derive_at"])
        lag = newest ? derive["lag_seconds"] : nil
        lagging = (lag && lag > LAG_LIMIT_SECONDS) || (last.nil? && raw_present[position])
        { "lag_seconds" => lag, "last_derive_at" => last, "newest_raw_at" => instant(newest), "dirty" => derive["dirty"],
          "torn_raw" => own.sum { |file| file["torn_raw"] }, "torn_derived" => own.sum { |file| file["torn_derived"] },
          "status" => lagging ? "lagging" : "ok" }
      rescue StandardError => e
        unreadable[position] = e.class.name
        unread_repo
      end

      def unread_repo
        { "lag_seconds" => nil, "last_derive_at" => nil, "newest_raw_at" => nil, "dirty" => nil, "torn_raw" => nil, "torn_derived" => nil,
          "status" => "unreadable" }
      end

      def owners(scopes, files, window)
        shared = files.select { |file| file["session"] }.group_by { |file| file["key"] }.values.select { |list| list.size > 1 }
        shared.each_with_object({}) do |list, out|
          list.sort_by { |file| file["scope"] }.each do |file|
            path = Record::Scope.derived_path(scopes[file["scope"]]["root"], file["key"])
            Reports::Records.each_line_record(path) do |record|
              out[record["id"]] ||= file["scope"] if record["kind"] == "usage" && window.holds?(record["ts"])
            end
          end
        end
      end
    end
  end
end
