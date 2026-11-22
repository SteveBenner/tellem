# frozen_string_literal: true

require_relative "../errors"
require_relative "../record/fs"
require_relative "../record/schemas"
require_relative "../record/scope"
require_relative "../record/visibility"
require_relative "../config/resolver"
require_relative "../ports/harness_paths"
require_relative "../specstory/anchor"
require_relative "../specstory/state"

module Tellem
  module Projections
    module SpecStory
      DIR = ".specstory"
      HISTORY = "history"
      NAME = /\A\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}[+-]\d{4}-[^\/]*\.md\z/

      module_function

      def history_dir(scope)
        File.join(scope, DIR, HISTORY)
      end

      def refresh(scope, check: false)
        enabled, reason = decide(scope)
        summary = { "enabled" => enabled, "reason" => reason, "dir" => history_dir(scope), "copies" => 0,
                    "changed" => [], "written" => 0, "conflicts" => [], "skipped" => [] }
        return summary unless enabled

        sources, conflicts = sources(scope)
        summary["conflicts"] = conflicts
        summary["copies"] = sources.size
        link = Record::FS.lstat(File.join(scope, DIR))&.symlink? ? linked(scope, summary) : nil
        return summary if link == :skipped

        if link
          Specstory::Anchor.anchored(link) { |fd| write_sources(scope, summary, sources, File.join(fd, HISTORY), check, linked: true) }
        else
          write_sources(scope, summary, sources, history_dir(scope), check, linked: false)
        end
        summary
      end

      def linked(scope, summary)
        dir = File.join(scope, DIR)
        real = Specstory::Anchor.named?(dir, Specstory::State.named_link_targets)
        return real if real

        summary["skipped"] << { "path" => dir, "target" => readlink(dir), "reason" => "symlink_target_not_named" }
        :skipped
      end

      def readlink(path)
        File.readlink(path)
      rescue SystemCallError
        nil
      end

      def write_sources(scope, summary, sources, dir, check, linked:)
        reconciled = false
        sources.each do |name, source|
          target = File.join(dir, name)
          bytes = Record::FS.read(source)
          next if current(target) == bytes

          summary["changed"] << name
          next if check

          linked ? prepare_linked(dir) : prepare(scope)
          reconciled ||= linked || Record::Visibility.reconcile(scope)
          Record::FS.replace(target, bytes)
          summary["written"] += 1
        rescue SymlinkRefused => e
          summary["skipped"] << { "path" => e.detail.is_a?(Hash) ? e.detail["path"] : dir, "reason" => "symlink_not_followed" }
          break
        end
      end

      def prepare_linked(dir)
        stat = Record::FS.lstat(dir)
        raise SymlinkRefused.new("symlinked SpecStory directory refused", detail: { "path" => dir }) if stat&.symlink?
        raise OperationalFailure.new("SpecStory path is not a directory", detail: { "path" => dir }) if stat && !stat.directory?

        Dir.mkdir(dir, Record::Schemas::DIR_MODE) unless stat
      rescue Errno::EEXIST
        nil
      end

      def decide(scope)
        return [false, "user scope"] unless Record::Scope.kind(scope) == "repository"

        state = Config.get("cutover.state", scope: scope)
        return [false, "cutover.state #{state}"] unless state == "cutover"

        writer = Config.get("specstory_writer", scope: scope)
        case writer
        when "on" then [true, "specstory_writer on"]
        when "auto" then automatic
        else [false, "specstory_writer #{writer}"]
        end
      end

      def automatic
        detected? ? [true, "specstory_writer auto, SpecStory detected"] : [false, "specstory_writer auto, SpecStory not detected"]
      rescue StandardError => e
        [false, "specstory_writer auto, SpecStory detection failed: #{e.class}"]
      end

      def detected?
        harness = Rplugin::Ports.for(Ports::HarnessPaths::PLUGIN_ID, root: Tellem.root).harness
        harness.specstory_detected? == true
      end

      def sources(scope)
        chosen = {}
        conflicts = []
        Record::Scope.session_keys(scope).each do |session_key|
          transcripts(scope, session_key).each do |name, path|
            if chosen.key?(name)
              conflicts << { "name" => name, "session_key" => session_key }
            else
              chosen[name] = path
            end
          end
        end
        [chosen.sort.to_h, conflicts]
      end

      def transcripts(scope, session_key)
        dir = Record::Scope.transcripts_dir(scope, session_key)
        stat = Record::FS.lstat(dir)
        return [] unless stat&.directory?

        Dir.children(dir).sort.filter_map do |name|
          next unless NAME.match?(name)

          path = File.join(dir, name)
          Record::FS.lstat(path)&.file? ? [name, path] : nil
        end
      rescue SystemCallError
        []
      end

      def current(target)
        Record::FS.read(target)
      rescue Errno::ENOENT, Errno::ENOTDIR
        nil
      end

      def prepare(scope)
        [File.join(scope, DIR), history_dir(scope)].each do |dir|
          stat = Record::FS.lstat(dir)
          raise SymlinkRefused.new("symlinked SpecStory directory refused", detail: { "path" => dir }) if stat&.symlink?
          raise OperationalFailure.new("SpecStory path is not a directory", detail: { "path" => dir }) if stat && !stat.directory?

          Dir.mkdir(dir, Record::Schemas::DIR_MODE) unless stat
        rescue Errno::EEXIST
          nil
        end
      end
    end
  end
end
