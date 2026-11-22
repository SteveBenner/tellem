# frozen_string_literal: true

require "open3"
require "set"
require "timeout"
require_relative "../config/resolver"
require_relative "../cutover/apply"
require_relative "../discovery"
require_relative "../errors"
require_relative "../ids"
require_relative "../ports/harness_paths"
require_relative "../record/exclude"
require_relative "../record/fs"
require_relative "anchor"
require_relative "startup"
require_relative "state"
require_relative "uninstall"
require_relative "verify"

module Tellem
  module Specstory
    module Plan
      DIR = ".specstory"
      HISTORY = "history"
      GIT_SECONDS = 15
      NOT_REPLACED = [
        "cross-agent resume of sessions",
        "SpecStory's other agents",
        "SpecStory's skills",
        "cloud sync, and any cloud copy, which tellem cannot delete"
      ].freeze
      WRAPPER_CHANGE = /\Aremove (function|alias) (\S+) \(lines \d+-\d+\)\z/.freeze
      CORE = %w[class kind base rel via file name shape bytes sha256].freeze

      module_function

      def build(history:, prevent:, link_targets:)
        paths = Ports::HarnessPaths.discovery_paths
        report = Discovery.run(paths)
        gate!(report)
        targets = link_targets.map { |path| Anchor.real_path(path) || File.expand_path(path) }.uniq.sort
        found = { items: [], kept: [], skipped: [] }
        wrapper_items(report, found)
        state_items(paths, targets, found, history: history)
        finish(report, found, history, prevent, targets)
      end

      def gate!(report)
        applied = Cutover.latest_applied
        subsumed = applied && Cutover.load(applied["plan_id"]).dig("request", "specstory") == "subsume" && Config.get("cutover.state") == "cutover"
        return if subsumed
        return unless Discovery.specstory_active?(report["methods"])

        raise CapabilityUnavailable.new("specstory remove needs the cutover state cutover with SpecStory subsumed, and SpecStory is still active on this host",
                                        next_command: "tellem cutover plan --specstory subsume", detail: { "cause" => "not_subsumed" })
      end

      def wrapper_items(report, found)
        report["methods"].each do |entry|
          next unless entry["kind"] == "wrapper" && entry["state"] == "present" && entry.dig("facts", "lines")

          facts = entry["facts"]
          file = facts["real_path"].is_a?(String) ? facts["real_path"] : facts["file"]
          real = Anchor.real_path(file)
          next unless real

          lines, blocks = Startup.blocks(real, facts["name"], facts["shape"])
          next if blocks.empty?

          text = blocks.map { |block| lines[(block[:from] - 1)..(block[:to] - 1)].join }.join
          found[:items] << { "class" => "wrapper", "kind" => "wrapper", "file" => real, "name" => facts["name"], "shape" => facts["shape"],
                             "bytes" => text.bytesize, "sha256" => Ids.sha256(text) }
        end
      end

      def roots(paths)
        Array(paths[:scopes]).reject { |root| Record::Exclude.covers?(root) }
      end

      def state_items(paths, targets, found, history: "keep")
        home_items(paths[:specstory_home], found)
        places(roots(paths), targets, found[:skipped]).each do |place|
          (found[:roots] ||= []) << place[:root]
          tracked = tracked_set(place)
          repo_items(place, tracked, found)
          history_items(place, tracked, found) if history == "remove"
        end
        found
      end

      def home_items(home, found)
        return unless home

        stat = Record::FS.lstat(home)
        return unless stat

        found[:home] = true
        if stat.symlink? || !stat.directory?
          found[:skipped] << { "path" => home, "reason" => stat.symlink? ? "symlink_not_followed" : "not_a_directory" }
          return
        end
        parent = Anchor.real_path(File.dirname(home))
        return unless parent

        place = { base: parent, via: nil, plain: true }
        files = []
        dirs = []
        walk(place, DIR, "state", files, dirs, found[:skipped], [])
        found[:items].concat(files, dirs, [dir_item("state", place, DIR)])
      end

      def link_target(path)
        File.readlink(path)
      rescue SystemCallError
        nil
      end

      def places(roots, targets, skipped)
        roots.filter_map do |root|
          dir = File.join(root, DIR)
          stat = Record::FS.lstat(dir)
          next unless stat

          if stat.symlink?
            real = Anchor.named?(dir, targets)
            next { root: root, base: real, via: dir, plain: false } if real

            skipped << { "path" => dir, "target" => link_target(dir), "reason" => "symlink_target_not_named" }
            next
          end
          next { root: root, base: dir, via: nil, plain: true } if stat.directory?

          skipped << { "path" => dir, "reason" => "not_a_directory" }
          nil
        end
      end

      def tracked_set(place)
        dir, spec = place[:plain] ? [place[:root], DIR] : [place[:base], "."]
        out, status = Timeout.timeout(GIT_SECONDS) { Open3.capture2("git", "-C", dir, "ls-files", "-z", "--", spec, err: File::NULL) }
        return Set.new unless status.success?

        out.split("\0").to_set
      rescue Errno::ENOENT, Timeout::Error
        nil
      end

      def tracked?(place, tracked, rel)
        key = place[:plain] ? File.join(DIR, rel) : rel
        tracked.include?(key)
      end

      def repo_items(place, tracked, found)
        files = []
        dirs = []
        walk(place, "", "repo", files, dirs, found[:skipped], [HISTORY])
        files.each do |item|
          if tracked.nil?
            found[:kept] << keep(item, "git_state_unknown")
          elsif tracked?(place, tracked, item["rel"])
            found[:kept] << keep(item, "tracked_in_git")
          else
            found[:items] << item
          end
        end
        found[:items].concat(dirs)
      end

      def history_items(place, tracked, found)
        dir = File.join(place[:base], HISTORY)
        stat = Record::FS.lstat(dir)
        return unless stat
        return found[:skipped] << { "path" => dir, "reason" => "symlink_not_followed" } if stat.symlink?
        return unless stat.directory?

        names = history_names(dir, found[:skipped])
        decisions = Verify.history(place[:root], dir, names, plain: place[:plain], gate: Verify.import_gate)
        names.each do |name|
          item = file_item("history", place, File.join(HISTORY, name))
          decision = decisions.fetch(name)
          if tracked.nil? then found[:kept] << keep(item, "git_state_unknown")
          elsif tracked?(place, tracked, item["rel"]) then found[:kept] << keep(item, "tracked_in_git")
          elsif decision["ok"] then found[:items] << item.merge("how" => decision["how"])
          else found[:kept] << keep(item, decision["reason"])
          end
        end
      end

      def history_names(dir, skipped)
        names = []
        Dir.children(dir).sort.each do |name|
          child = Record::FS.lstat(File.join(dir, name))
          if child&.file?
            names << name
          else
            skipped << { "path" => File.join(dir, name), "reason" => child&.symlink? ? "symlink_not_followed" : "not_a_regular_file" }
          end
        end
        names
      end

      def keep(item, reason)
        { "path" => File.join(item["base"], item["rel"]), "class" => item["class"], "reason" => reason, "bytes" => item["bytes"] }
      end

      def walk(place, rel, cls, files, dirs, skipped, top_skip)
        dir = rel.empty? ? place[:base] : File.join(place[:base], rel)
        Dir.children(dir).sort.each do |name|
          next if rel.empty? && top_skip.include?(name)

          child = rel.empty? ? name : File.join(rel, name)
          path = File.join(place[:base], child)
          stat = Record::FS.lstat(path)
          next unless stat

          if stat.symlink?
            skipped << { "path" => path, "reason" => "symlink_not_followed" }
          elsif stat.directory?
            walk(place, child, cls, files, dirs, skipped, [])
            dirs << dir_item(cls, place, child)
          elsif stat.file?
            files << file_item(cls, place, child)
          else
            skipped << { "path" => path, "reason" => "not_a_regular_file" }
          end
        end
      end

      def file_item(cls, place, rel)
        path = File.join(place[:base], rel)
        stat = Record::FS.lstat(path)
        digest = Anchor.digest(path)
        { "class" => cls, "kind" => "file", "base" => place[:base], "rel" => rel, "via" => place[:via], "bytes" => digest["bytes"],
          "sha256" => digest["sha256"], "size" => stat.size, "inode" => stat.ino, "mtime_ns" => Anchor.mtime_ns(stat) }
      end

      def dir_item(cls, place, rel)
        { "class" => cls, "kind" => "dir", "base" => place[:base], "rel" => rel, "via" => place[:via], "bytes" => 0 }
      end

      def order(items)
        wrappers = items.select { |item| item["kind"] == "wrapper" }.sort_by { |item| [item["file"], item["name"]] }
        files = items.select { |item| item["kind"] == "file" }.sort_by { |item| [item["base"], item["rel"]] }
        dirs = items.select { |item| item["kind"] == "dir" }.sort_by { |item| [item["base"], -item["rel"].count("/"), item["rel"]] }
        wrappers + files + dirs
      end

      def finish(report, found, history, prevent, targets)
        items = order(found[:items].uniq)
        core = items.map { |item| item.slice(*CORE) }
        named = (removed_wrappers + items.select { |item| item["kind"] == "wrapper" }.map { |item| item.slice("file", "name", "shape") }).uniq
        named_roots = Array(found[:roots]).uniq.sort
        id = Ids.sha256(Ids.canonical_json([history, prevent, targets, core, named, named_roots, found[:home] == true]))[0, 12]
        state_facts = report["methods"].find { |entry| entry["kind"] == "specstory_state" }&.fetch("facts", nil) || {}
        {
          "plan_id" => id, "history" => history, "prevent" => prevent, "link_targets" => targets, "items" => items,
          "named_wrappers" => named, "roots" => named_roots, "home" => found[:home] == true, "kept" => found[:kept].sort_by { |item| item["path"] }, "skipped" => found[:skipped].sort_by { |item| item["path"] },
          "programs" => programs(report), "uninstall" => Uninstall.describe(Ports::HarnessPaths.discovery_paths[:path]),
          "not_replaced" => NOT_REPLACED, "cloud_sync" => state_facts["cloud_sync_enabled"] == true,
          "files" => items.count { |item| item["kind"] == "file" }, "bytes" => items.sum { |item| item["bytes"].to_i }
        }
      end

      def removed_wrappers
        applied = Cutover.latest_applied
        return [] unless applied

        Cutover.load(applied["plan_id"])["files"].to_a.select { |file| Array(file["roles"]).include?("wrapper") }.flat_map do |file|
          Array(file["changes"]).filter_map do |change|
            match = WRAPPER_CHANGE.match(change)
            match && { "file" => file["path"], "name" => match[2], "shape" => match[1] }
          end
        end
      rescue OperationalFailure
        []
      end

      def programs(report)
        present = report["methods"].select { |entry| entry["state"] == "present" }
        {
          "processes" => present.select { |entry| entry["kind"] == "process" }.map { |entry| entry["id"] },
          "schedules" => present.select { |entry| entry["kind"] == "schedule" }.map { |entry| entry["id"] },
          "hooks" => present.select { |entry| entry["kind"] == "repo_output" && entry.dig("facts", "post_checkout") }
                            .map { |entry| entry.dig("facts", "post_checkout", "path") }
        }
      end

      def display(item)
        item["kind"] == "wrapper" ? "#{item['file']} (#{item['shape']} #{item['name']})" : File.join(item["base"], item["rel"])
      end

      def text(plan)
        lines = ["specstory removal plan #{plan['plan_id']} (history #{plan['history']}, prevent #{plan['prevent'] ? 'on' : 'off'})"]
        plan["items"].each do |item|
          size = item["kind"] == "file" ? "  #{item['bytes']} bytes" : ""
          how = item["how"] ? " (#{item['how']})" : ""
          lines << "  remove #{item['class']} #{item['kind']} #{display(item)}#{size}#{how}"
        end
        plan["kept"].each { |item| lines << "  keep #{item['path']}: #{item['reason']}" }
        plan["skipped"].each { |item| lines << "  skip #{item['path']}: #{item['reason']}#{item['target'] ? " -> #{item['target']}" : ''}" }
        lines << "  nothing to remove" if plan["items"].empty?
        lines << "  total #{plan['files']} files, #{plan['bytes']} bytes; a removal cannot be rolled back"
        lines << "  warning: SpecStory cloud sync was on; tellem cannot delete a cloud copy" if plan["cloud_sync"]
        lines << "  not replaced by tellem: #{plan['not_replaced'].join('; ')}"
        programs = plan["programs"]
        running = programs["processes"] + programs["schedules"]
        lines << "  returned program, reported only: #{running.join(', ')}" unless running.empty?
        lines << "  git hooks that mention SpecStory, not removed: #{programs['hooks'].join(', ')}" unless programs["hooks"].empty?
        lines << "  readers keep .specstory/history; tellem keeps writing it (specstory_writer on unless the operator set it off)"
        uninstall = plan["uninstall"]
        lines << (uninstall["found"] ? "  uninstall the program yourself (tellem never runs this): #{uninstall['command']}" : "  no specstory program found on PATH")
        lines.join("\n")
      end
    end
  end
end
