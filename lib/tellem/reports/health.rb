# frozen_string_literal: true

require "time"
require_relative "../ports/harness_paths"
require_relative "../record/fs"
require_relative "../record/scope"
require_relative "mirror"
require_relative "records"
require_relative "text"

module Tellem
  module Reports
    module Health
      SLO_P99_MS = 50

      module_function

      def run(scopes, now: Time.now)
        {
          "scopes" => scopes.map { |scope| scope["gone"] ? scope.merge("health" => nil) : scope.merge("health" => scope_health(scope, now)) },
          "hook_gaps" => hook_gaps
        }
      end

      def scope_health(scope, now)
        root = scope["root"]
        samples = Hash.new { |hash, key| hash[key] = [] }
        newest = nil
        raw_torn = 0
        raw_count = 0
        Record::Scope.session_keys(root).each do |key|
          raw_files(root, key).each do |path|
            raw_torn += Records.each_line_record(path) do |record|
              raw_count += 1
              newest = record["ts"] if record["ts"].is_a?(String) && (newest.nil? || record["ts"] > newest)
              samples[[record["harness"].to_s, record["event"].to_s]] << record["hook_ms"] if record["hook_ms"].is_a?(Integer)
            end
          end
        end
        data = Records.load(scope)
        {
          "raw_observations" => raw_count,
          "derived_observations" => data.records.size,
          "torn_lines" => { "raw" => raw_torn, "derived" => data.torn },
          "hook_ms" => hook_ms(samples),
          "gaps" => gaps(data),
          "derive" => derive_lag(root, newest),
          "mirror" => mirror(scope)
        }
      end

      def raw_files(root, key)
        dir = Record::Scope.raw_dir(root, key)
        stat = Record::FS.lstat(dir)
        return [] unless stat&.directory?

        Dir.children(dir).sort.filter_map do |name|
          path = File.join(dir, name)
          name.end_with?(".jsonl") && Record::FS.lstat(path)&.file? ? path : nil
        end
      rescue SystemCallError
        []
      end

      def hook_ms(samples)
        all = samples.values.flatten
        groups = samples.keys.sort.map { |harness, event| stats(samples[[harness, event]]).merge("harness" => harness, "event" => event) }
        { "overall" => stats(all), "groups" => groups, "slo_p99_ms" => SLO_P99_MS }
      end

      def stats(values)
        return { "count" => 0, "p50" => nil, "p99" => nil, "max" => nil } if values.empty?

        sorted = values.sort
        { "count" => sorted.size, "p50" => rank(sorted, 50), "p99" => rank(sorted, 99), "max" => sorted.last }
      end

      def rank(sorted, percentile)
        sorted[[(percentile / 100.0 * sorted.size).ceil - 1, 0].max]
      end

      def gaps(data)
        totals = Hash.new(0)
        data.of_kind("gap").each do |record|
          body = record["body"] || {}
          count = body["count"].is_a?(Integer) ? body["count"] : 1
          totals[[body["cause"].to_s, body["harness"]]] += count
        end
        rows = totals.keys.sort_by { |cause, harness| [cause, harness.to_s] }.map { |cause, harness| { "cause" => cause, "harness" => harness, "count" => totals[[cause, harness]] } }
        { "total" => totals.values.sum, "by_cause" => rows }
      end

      def derive_lag(root, newest)
        cursor = Record::FS.lstat(Record::Scope.cursor_file(root))
        last = cursor&.file? ? cursor.mtime.utc : nil
        lag = if newest.nil? then 0
              elsif last.nil? then nil
              else [(Time.iso8601(newest) - last).ceil, 0].max
              end
        { "newest_raw_at" => newest, "last_derive_at" => last&.strftime("%Y-%m-%dT%H:%M:%SZ"), "lag_seconds" => lag,
          "dirty" => Record::FS.lexists?(Record::Scope.dirty_file(root)) }
      rescue ArgumentError
        { "newest_raw_at" => newest, "last_derive_at" => nil, "lag_seconds" => nil, "dirty" => false }
      end

      def mirror(scope)
        adapter = Array(Mirror.adapters([scope])).first
        return { "kind" => "none" } if adapter.nil? || adapter.kind == "none"

        status = adapter.status
        entry = Array(status[:scopes]).find { |item| item["scope_id"] == scope["scope_id"] }
        { "kind" => status[:kind], "location" => status[:location], "reachable" => status[:reachable], "provisioned" => status[:provisioned],
          "breaker" => status[:breaker], "failures" => status[:failures], "lag_seconds" => entry ? entry["lag_seconds"] : status[:lag_seconds],
          "last_sync_at" => status[:last_sync_at], "error" => status[:error] }.compact
      rescue StandardError => e
        { "kind" => "unknown", "error_class" => e.class.name }
      end

      def hook_gaps
        path = Ports::HarnessPaths.hook_gaps
        totals = Hash.new(0)
        torn = Records.each_line_record(path) { |record| totals[record["cause"].to_s] += 1 }
        { "path" => path, "total" => totals.values.sum, "torn_lines" => torn,
          "by_cause" => totals.keys.sort.map { |cause| { "cause" => cause, "count" => totals[cause] } } }
      end

      def text(report)
        lines = report["scopes"].flat_map do |scope|
          next ["#{scope['root']}: gone"] unless scope["health"]

          health = scope["health"]
          overall = health["hook_ms"]["overall"]
          derive = health["derive"]
          mirror = health["mirror"]
          ["#{scope['root']} (#{scope['scope_id']})",
           "  hook_ms: #{overall['count']} samples, p50 #{Text.cell(overall['p50'])}, p99 #{Text.cell(overall['p99'])}, max #{Text.cell(overall['max'])} (slo p99 < #{SLO_P99_MS})",
           *health["hook_ms"]["groups"].map { |group| "    #{group['harness']} #{group['event']}: #{group['count']} samples, p99 #{group['p99']}" },
           "  observations: #{health['raw_observations']} raw, #{health['derived_observations']} derived; torn lines #{health['torn_lines']['raw']} raw, #{health['torn_lines']['derived']} derived",
           "  gaps: #{health['gaps']['total']}#{health['gaps']['by_cause'].map { |row| " #{row['cause']}=#{row['count']}" }.join}",
           "  derive lag: #{derive['lag_seconds'].nil? ? 'never derived' : "#{derive['lag_seconds']} s"}#{derive['dirty'] ? ' (dirty)' : ''}",
           "  mirror: #{mirror['kind']}#{mirror['kind'] == 'none' ? '' : " lag #{Text.cell(mirror['lag_seconds'])} s, reachable #{mirror['reachable'] ? 'yes' : 'no'}, breaker #{mirror['breaker']}"}"]
        end
        gaps = report["hook_gaps"]
        (lines + ["hook gaps: #{gaps['total']}#{gaps['by_cause'].map { |row| " #{row['cause']}=#{row['count']}" }.join}"]).join("\n")
      end
    end
  end
end
