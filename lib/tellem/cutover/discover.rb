# frozen_string_literal: true

require "json"
require "find"
require_relative "../record/fs"

module Tellem
  module Cutover
    module Discover
      HOOK_DIRS = [File.join("claude", "hooks"), File.join("codex", "hooks")].freeze
      SETTINGS = [File.join("claude", "settings.json"), File.join("claude", "settings.local.json")].freeze
      UNREGISTERED = File.join("claude", "hooks", "UNREGISTERED")
      CAPTURES = { "specstory_sync" => /\bspecstory\s+sync\b/, "tokens_ledger" => /TOKENS\.jsonl/ }.freeze
      RULE_FILES = [/\A(?:.+\/)?AGENTS\.md\z/, %r{\Adirectives/.+\.md\z}, %r{\Aclaude/rules/.+\.md\z}, %r{\Aclaude/skills/directive-[^/]+/SKILL\.md\z}].freeze
      NAMES = /specstory|TOKENS\.jsonl/i
      SKIP_DIRS = %w[.git .specstory .backup node_modules __pycache__ specs].freeze
      SKIP_FILES = %w[DECISIONS.md CHANGELOG.md TOKENS.jsonl].freeze
      TEXT_LIMIT = 1024 * 1024
      LINE_LIMIT = 240

      module_function

      def run(ai_home)
        hooks = hooks(ai_home)
        names = hooks.map { |hook| hook["name"] }
        {
          "hooks" => hooks,
          "registrations" => registrations(ai_home, names),
          "rules" => rules(ai_home),
          "callers" => callers(ai_home, names)
        }
      end

      def hooks(ai_home)
        HOOK_DIRS.flat_map do |dir|
          base = File.join(ai_home, dir)
          next [] unless Record::FS.lstat(base)&.directory?

          Dir.children(base).sort.filter_map do |name|
            path = File.join(base, name)
            stat = Record::FS.lstat(path)
            next unless stat&.file? && stat.size <= TEXT_LIMIT

            text = read_text(path)
            captures = CAPTURES.select { |_kind, pattern| text&.match?(pattern) }.keys
            next if captures.empty?

            { "name" => name, "path" => File.join(dir, name), "captures" => captures }
          end
        end
      end

      def registrations(ai_home, names)
        SETTINGS.flat_map do |rel|
          data = settings(File.join(ai_home, rel))
          next [] unless data

          entries(data).filter_map do |event, command|
            hook = names.find { |name| incumbent_command?(command, name) }
            { "file" => rel, "event" => event, "command" => command, "hook" => hook } if hook
          end
        end
      end

      def settings(path)
        stat = Record::FS.lstat(path)
        return nil unless stat&.file?

        data = JSON.parse(Record::FS.read(path))
        data.is_a?(Hash) ? data : nil
      rescue JSON::ParserError, SystemCallError
        nil
      end

      def entries(data)
        hooks = data["hooks"].is_a?(Hash) ? data["hooks"] : {}
        hooks.flat_map do |event, groups|
          Array(groups).flat_map do |group|
            list = group.is_a?(Hash) ? Array(group["hooks"]) : []
            list.filter_map { |hook| [event, hook["command"]] if hook.is_a?(Hash) && hook["command"].is_a?(String) }
          end
        end
      end

      def incumbent_command?(command, name)
        command.split(/\s+/).any? { |word| File.basename(word.delete("\"'")) == name }
      end

      def rules(ai_home)
        each_text(ai_home) do |rel, _path|
          RULE_FILES.any? { |pattern| pattern.match?(rel) }
        end.flat_map { |rel, text| mentions(rel, text, NAMES) }
      end

      def callers(ai_home, names)
        return [] if names.empty?

        pattern = Regexp.union(names)
        own = HOOK_DIRS.flat_map { |dir| names.map { |name| File.join(dir, name) } } + SETTINGS + [UNREGISTERED]
        each_text(ai_home) do |rel, _path|
          !own.include?(rel) && RULE_FILES.none? { |rule| rule.match?(rel) }
        end.flat_map { |rel, text| mentions(rel, text, pattern) }
      end

      def mentions(rel, text, pattern)
        text.each_line.with_index(1).filter_map do |line, number|
          next unless line.match?(pattern)

          { "file" => rel, "line" => number, "text" => line.chomp.strip[0, LINE_LIMIT] }
        end
      end

      def each_text(ai_home)
        found = []
        Find.find(ai_home) do |path|
          name = File.basename(path)
          stat = Record::FS.lstat(path)
          next unless stat

          if stat.directory?
            Find.prune if path != ai_home && SKIP_DIRS.include?(name)
            next
          end
          next unless stat.file? && stat.size <= TEXT_LIMIT && !SKIP_FILES.include?(name)

          rel = path.delete_prefix("#{ai_home}/")
          next unless yield(rel, path)

          text = read_text(path)
          found << [rel, text] if text
        end
        found.sort_by(&:first)
      end

      def read_text(path)
        text = Record::FS.read(path)
        return nil if text.include?("\0")

        text.force_encoding(Encoding::UTF_8).valid_encoding? ? text : text.encode("UTF-8", "binary", invalid: :replace, undef: :replace)
      rescue SystemCallError, SymlinkRefused
        nil
      end
    end
  end
end
