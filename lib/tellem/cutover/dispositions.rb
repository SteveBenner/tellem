# frozen_string_literal: true

require_relative "../record/fs"
require_relative "callers"
require_relative "discover"

module Tellem
  module Cutover
    module Dispositions
      EDIT = "edit"
      NONE = "none"
      UNRESOLVED = "unresolved"
      BACKUP = /(?:\A|\/)\.backup\/|\.bak\b|\.backup\b|backup-/i
      HISTORY_NAMES = /\A(?:CHANGELOG|DECISIONS|NOTES|WIP|HISTORY)\b/
      HISTORY_DIRS = %r{(?:\A|/)\.rproject/}
      OUTPUT = %r{(?:\A|/)(?:debug|logs?)/|\.log\z}
      DOC = /\.(?:md|markdown|txt|rst)\z/i
      SCRIPT = /\.(?:sh|bash|zsh|py|rb)\z/
      COMMENT = %r{\A\s*(?:#|//|<!--)}
      GENERATED = %r{\Aclaude/skills/directive-([^/]+)/SKILL\.md\z}
      REASONS = {
        hook: "the hook script stays on disk; after apply no settings file registers it, claude/hooks/UNREGISTERED lists it, and rollback registers it again",
        backup: "a backup copy that no harness or tool loads",
        history: "a record of past work, and history is not rewritten",
        output: "output a harness wrote in the past; nothing reads it as instructions",
        comment: "only comments name the hook",
        doc: "documentation of the incumbent scripts, which stay on disk; it registers and runs nothing",
        rule: "names SpecStory or TOKENS.jsonl as history, an output, or a reading source and registers no capture; " \
              "prior .specstory/history files and ledgers stay in place, and tellem keeps writing .specstory/history while specstory_writer is on",
        helper: "runs the hook script outside any hook event, since no settings file registers this script as a hook, so it captures nothing; " \
                "the script stays on disk, so the call keeps working",
        remaining_rule: "the other lines describe SpecStory or TOKENS.jsonl as outputs and history that stay; reword them by hand if wanted",
        settled: "already holds what this plan sets, so it needs no edit"
      }.freeze

      module_function

      def run(build, found, hook_names, extras)
        commands = hook_commands(build.ai_home)
        discovered(found, extras).map do |route, kinds|
          lines = mention_lines(found, route)
          entry = build.entry_for(route)
          item = { "file" => route, "found_as" => kinds }
          if entry
            item.merge(edited(entry, route, lines, hook_names))
          elsif build.notes[route]
            item.merge("disposition" => UNRESOLVED, "reason" => build.notes[route])
          elsif extras.key?(route) && (kinds - extras[route]).empty?
            item.merge("disposition" => NONE, "reason" => REASONS[:settled])
          else
            reason = reason(build.ai_home, route, kinds, lines, commands)
            item.merge(reason ? { "disposition" => NONE, "reason" => reason } : { "disposition" => UNRESOLVED, "reason" => "no edit rule applies; edit it by hand, then plan again" })
          end
        end
      end

      def discovered(found, extras)
        kinds = Hash.new { |hash, key| hash[key] = [] }
        found["hooks"].each { |hook| kinds[hook["path"]] |= ["hook"] }
        found["registrations"].each { |entry| kinds[entry["file"]] |= ["registration"] }
        found["rules"].each { |entry| kinds[entry["file"]] |= ["rule"] }
        found["callers"].each { |entry| kinds[entry["file"]] |= ["caller"] }
        extras.each { |route, names| kinds[route] |= names }
        kinds.sort_by { |route, _| route }
      end

      def mention_lines(found, route)
        (found["rules"] + found["callers"]).select { |entry| entry["file"] == route }.map { |entry| entry.slice("line", "text") }.uniq
      end

      def edited(entry, route, lines, hook_names)
        item = { "disposition" => EDIT, "path" => entry["path"], "changes" => entry["changes"] }
        item["reached_through"] = entry["routes"] if entry["routes"].size > 1
        left = left_over(entry, route, lines, hook_names)
        return item if left.empty?
        return item.merge("disposition" => UNRESOLVED, "reason" => "lines #{left.join(', ')} still run an incumbent hook after the edit") if Callers.python?(route)

        item.merge("remaining" => { "lines" => left, "reason" => REASONS[:remaining_rule] })
      end

      def left_over(entry, route, lines, hook_names)
        return [] if lines.empty?

        after = entry["after"].to_s.dup.force_encoding(Encoding::UTF_8)
        return Callers.remaining(after, hook_names) if Callers.python?(route)

        pattern = Regexp.union(Discover::NAMES, *hook_names)
        after.each_line.with_index(1).select { |line, _| line.match?(pattern) }.map(&:last)
      end

      def reason(ai_home, route, kinds, lines, commands)
        return REASONS[:hook] if kinds == ["hook"]
        return REASONS[:backup] if BACKUP.match?(route)
        return REASONS[:history] if HISTORY_NAMES.match?(File.basename(route)) || HISTORY_DIRS.match?(route)
        return REASONS[:output] if OUTPUT.match?(route)

        generated = generated(ai_home, route)
        return generated if generated
        return REASONS[:comment] if !lines.empty? && lines.all? { |line| COMMENT.match?(line["text"]) }
        return REASONS[:rule] if kinds.include?("rule")
        return REASONS[:doc] if DOC.match?(route)
        return REASONS[:helper] if SCRIPT.match?(route) && !Callers.python?(route) && commands.none? { |command| names?(command, route) }

        nil
      end

      def generated(ai_home, route)
        match = GENERATED.match(route)
        return nil unless match

        source = File.join("directives", "#{match[1]}.md")
        return nil unless Record::FS.lstat(File.join(ai_home, source))&.file?

        "a generated copy of the body of #{source}; it changes only when that body changes, and this plan edits no directive body"
      end

      def hook_commands(ai_home)
        return [] unless ai_home

        Discover::SETTINGS.flat_map do |rel|
          data = Discover.settings(File.join(ai_home, rel))
          data ? Discover.entries(data).map(&:last) : []
        end
      end

      def names?(command, route)
        command.split(/\s+/).any? { |word| File.basename(word.delete("\"'")) == File.basename(route) }
      end
    end
  end
end
