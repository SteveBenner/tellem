# frozen_string_literal: true

require_relative "../backends/reports"
require_relative "../backends/rows"
require_relative "../otel/report_details"
require_relative "../record/kinds"
require_relative "../record/reader"
require_relative "mirror"
require_relative "options"
require_relative "records"
require_relative "scan"
require_relative "text"

module Tellem
  module Reports
    module Tokens
      COUNTERS = Record::Kinds::COUNTERS
      FIELD = {
        "agent" => "agent_key", "session" => "session_key", "model" => "model", "effort" => "effort", "persona" => "persona_key",
        "repository" => "repository_id", "place" => "place_id", "day" => "ts", "subagent_type" => "subagent_type", "type" => "subagent_type"
      }.freeze

      module_function

      def params(by: nil, session: nil, since: nil, until_time: nil)
        {
          "by" => Backends::Reports.dimensions({ "by" => by }),
          "session" => session,
          "since" => Options.time_bound(since, "--since"),
          "until" => Options.time_bound(until_time, "--until")
        }
      end

      def run(scopes, params, workers: nil)
        rows, source = collect(scopes, params, workers: workers)
        [with_roots(rows, scopes, params), source]
      end

      def with_roots(rows, scopes, params)
        return rows unless params["by"].include?("repository")

        roots = repository_roots(scopes.reject { |item| item["gone"] })
        rows.map do |row|
          root = roots[row["repository"]]
          row.to_a.flat_map { |key, value| key == "repository" ? [[key, value], ["repository_root", root]] : [[key, value]] }.to_h
        end
      end

      def repository_roots(scopes)
        roots = {}
        scopes.each do |scope|
          Records.derived_files(scope["root"]).each do |_key, path|
            Record::Reader.each(path) do |record|
              body = record["body"]
              next unless record["kind"] == "repository" && body.is_a?(Hash) && body["repository_id"] && body["common_dir"]

              roots[body["repository_id"]] ||= body["common_dir"].delete_suffix("/.git")
            end
          end
        end
        roots
      end

      def collect(scopes, params, workers: nil)
        live = scopes.reject { |item| item["gone"] }
        mirror = Mirror.current(live)
        if mirror
          rows = Mirror.query(mirror, "tokens", params.merge("scope_ids" => live.map { |item| item["scope_id"] }))
          return [rows, mirror.kind] if rows
        end
        [from_files(live, params, workers: workers), "files"]
      end

      def columns(params)
        list = %w[id ts session_key]
        list.concat(params["by"].map { |dim| FIELD.fetch(dim) })
        list.concat(%w[harness request_key effort cost_usd])
        list.uniq + COUNTERS
      end

      def from_files(scopes, params, workers: nil)
        rows, index = request_rows(scopes, params, workers: workers)
        aggregate(rows, params["by"], index)
      end

      def request_rows(scopes, params, workers: nil)
        names = columns(params)
        index = names.each_with_index.to_h
        jobs = scopes.flat_map { |scope| Records.derived_files(scope["root"]).map { |_key, path| [scope["scope_id"], path] } }
        results = Scan.run(jobs.map(&:last), names, workers: workers)
        Otel::ReportDetails.apply(jobs, results, index)
        [covered_rows(jobs, results, params, index), index]
      end

      def covered_rows(jobs, results, params, index)
        rows = Hash.new { |hash, key| hash[key] = {} }
        superseded = Hash.new { |hash, key| hash[key] = {} }
        ts = index.fetch("ts")
        session = index.fetch("session_key")
        jobs.each_with_index do |(scope_id, _path), position|
          tuples, supersedes = results[position]
          marks = superseded[scope_id]
          supersedes.each { |id| marks[id] = true }
          kept = rows[scope_id]
          tuples.each do |tuple|
            current = kept[tuple[0]]
            kept[tuple[0]] = tuple if current.nil? || Scan.earlier?(tuple, current, ts, session)
          end
        end
        filter = filter(params, index)
        chosen = {}
        stale = {}
        rows.keys.sort.each do |scope_id|
          marks = superseded[scope_id]
          rows[scope_id].each do |id, tuple|
            next if filter && !filter.call(tuple)

            chosen[id] ||= tuple
            stale[id] = true if marks.key?(id)
          end
        end
        stale.each_key { |id| chosen.delete(id) }
        chosen.values
      end

      def filter(params, index)
        session = params["session"]&.to_s
        since = params["since"]
        before = params["until"]
        return nil unless session || since || before

        ts = index["ts"]
        key = index["session_key"]
        lambda do |tuple|
          next false if session && tuple[key] != session
          next false if since && tuple[ts].to_s < since
          next false if before && tuple[ts].to_s >= before

          true
        end
      end

      def aggregate(rows, dims, index)
        positions = dims.map { |dim| index.fetch(FIELD.fetch(dim)) }
        days = dims.map { |dim| dim == "day" }
        counters = COUNTERS.map { |name| index.fetch(name) }
        cost = index.fetch("cost_usd")
        groups = {}
        rows.each do |tuple|
          key = positions.each_with_index.map { |position, i| days[i] ? tuple[position].to_s[0, 10] : tuple[position] }
          group = groups[key] ||= [0, Array.new(COUNTERS.size), 0, 0]
          group[0] += 1
          sums = group[1]
          counters.each_with_index do |position, i|
            number = tuple[position]
            sums[i] = sums[i].to_i + number unless number.nil?
          end
          next if tuple[cost].nil?

          group[2] += tuple[cost]
          group[3] += 1
        end
        any = groups.each_value.any? { |group| group[3].positive? }
        groups.keys.sort { |left, right| compare(left, right) }.map do |key|
          count, sums, units, costed = groups[key]
          row = dims.each_with_index.to_h { |dim, i| [dim, key[i]] }
          row["requests"] = count
          COUNTERS.each_with_index { |name, i| row[name] = sums[i] }
          row["cost_usd"] = costed.positive? ? Backends::Rows.cost_usd(units) : nil if any
          row
        end
      end

      def compare(left, right)
        left.each_index do |i|
          a = left[i]
          b = right[i]
          next if a == b
          return -1 if a.nil?
          return 1 if b.nil?

          result = a.to_s.b <=> b.to_s.b
          return result unless result.zero?
        end
        0
      end

      def text(rows, dims)
        headers = dims.flat_map { |dim| dim == "repository" ? [dim, "repository_root"] : [dim] } + ["requests"] + COUNTERS
        table = rows.map { |row| headers.map { |name| row[name].nil? ? "-" : row[name].to_s } }
        Text.table(headers, table)
      end
    end
  end
end
