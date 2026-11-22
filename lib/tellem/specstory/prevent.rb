# frozen_string_literal: true

require "time"
require_relative "../authority/switch"
require_relative "../discovery"
require_relative "../ports/harness_paths"
require_relative "plan"
require_relative "remove"
require_relative "state"
require_relative "uninstall"

module Tellem
  module Specstory
    module Prevent
      SCAN_SECONDS = 10
      RECENT_S = 86_400
      KEEP_REMOVALS = 50

      module_function

      def scan(state)
        paths = Ports::HarnessPaths.discovery_paths
        ctx = Discovery::Context.new(paths: paths)
        named_paths = paths.merge(scopes: Array(state["roots"]), specstory_home: state["home"] ? paths[:specstory_home] : nil)
        deadline = Discovery::Bounds.deadline(SCAN_SECONDS)
        present = Discovery::Incumbent.wrappers(ctx, deadline).select { |entry| entry["state"] == "present" && entry.dig("facts", "lines") }
        named = Array(state["wrappers"]).map { |item| item.slice("file", "name", "shape") }
        mine, other = present.partition { |entry| named.include?(identity(entry["facts"])) }
        found = { items: [], kept: [], skipped: [] }
        Plan.wrapper_items({ "methods" => mine }, found)
        Plan.state_items(named_paths, Array(state["link_targets"]), found)
        {
          items: Plan.order(found[:items].uniq), kept: found[:kept], skipped: found[:skipped],
          unnamed_wrappers: other.map { |entry| entry["id"] }, programs: programs(ctx, deadline, paths)
        }
      end

      def identity(facts)
        file = facts["real_path"].is_a?(String) ? facts["real_path"] : facts["file"]
        { "file" => Anchor.real_path(file) || file, "name" => facts["name"], "shape" => facts["shape"] }
      end

      def programs(ctx, deadline, paths)
        running = Discovery::Incumbent.processes(ctx, deadline) + Discovery::Incumbent.schedules(ctx, deadline)
        found = running.select { |entry| entry["state"] == "present" }.map { |entry| entry["id"] }
        binary = Uninstall.find(paths[:path])
        found << "binary:#{binary}" if binary
        found
      end

      def after_registry(totals)
        Remove.resume unless Remove.open_plans.empty?
        state = State.read
        return unless state

        found = scan(state)
        held = hold_reason(state)
        removed = nil
        if held.nil? && !found[:items].empty?
          outcome = State.exclusive do
            Remove.resume_open
            Remove.drift(found[:items])
          end
          removed = outcome unless outcome == :busy
        end
        record(found, held, removed)
      rescue StandardError => e
        totals.errors << { "phase" => "specstory", "error_class" => e.class.name, "message" => e.message[0, 200] }
      end

      def hold_reason(state)
        return "authority_stopped" if Authority::Switch.off?

        state["prevent"] == false ? "prevent_off" : nil
      end

      def record(found, held, removed)
        previous = State.read_drift || {}
        earlier = Array(previous["removed"])
        now = Record::FS.rfc3339
        added = removed ? [{ "at" => now, "plan_id" => removed[:plan_id], "removed" => removed[:removed], "kept" => removed[:kept].size }] : []
        data = { "at" => now, "held" => held, "returned" => found[:items].size, "unnamed_wrappers" => found[:unnamed_wrappers],
                 "programs" => found[:programs], "removed" => (earlier + added).last(KEEP_REMOVALS) }
        State.write_drift(data) unless data.reject { |key, _| key == "at" } == previous.reject { |key, _| key == "at" }
      end

      def status
        state = State.read
        return { "removed" => false } unless state

        found = scan(state)
        drift = State.read_drift || {}
        {
          "removed" => true, "plan_id" => state["plan_id"], "applied_at" => state["applied_at"], "prevent" => state["prevent"] != false,
          "history" => state["history"], "writer" => state["writer"], "stop_switch" => Authority::Switch.reason, "held" => hold_reason(state),
          "returned" => found[:items].map { |item| Plan.display(item) }, "unnamed_wrappers" => found[:unnamed_wrappers], "programs" => found[:programs],
          "recent_removals" => Array(drift["removed"]).select { |item| recent?(item["at"]) }, "open_plans" => Remove.open_plans.map { |item| item["plan_id"] }
        }
      end

      def recent?(stamp)
        Time.now - Time.iso8601(stamp.to_s) < RECENT_S
      rescue ArgumentError
        false
      end

      def findings(info = status)
        return [] unless info["removed"]

        out = []
        hold = info["held"] ? " (#{info['held']}: nothing is removed)" : ""
        out << "SpecStory state or wrappers returned after removal: #{info['returned'].first(5).join(', ')}#{hold}" unless info["returned"].empty?
        out << "a SpecStory wrapper not named by the removal plan is present: #{info['unnamed_wrappers'].join(', ')}" unless info["unnamed_wrappers"].empty?
        out << "a SpecStory program or schedule is present, reported only: #{info['programs'].join(', ')}" unless info["programs"].empty?
        info["recent_removals"].each { |item| out << "SpecStory returned and was removed at #{item['at']} (#{item['removed']} items, plan #{item['plan_id']})" }
        out << "a SpecStory removal is unfinished: #{info['open_plans'].join(', ')}" unless info["open_plans"].empty?
        out
      end
    end
  end
end
