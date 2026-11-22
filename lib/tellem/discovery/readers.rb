# frozen_string_literal: true

require "shellwords"
require_relative "../cutover/discover"
require_relative "../ports/harness_paths"
require_relative "bounds"
require_relative "capabilities"
require_relative "plugins"
require_relative "records"
require_relative "toml"

module Tellem
  module Discovery
    module Readers
      PLUGIN = Ports::HarnessPaths::PLUGIN_ID
      PATTERNS = {
        "transcript_path" => /transcript_path/,
        "agent_transcript_path" => /agent_transcript_path/,
        ".claude/projects" => %r{\.claude/projects},
        ".codex/sessions" => %r{\.codex/sessions}
      }.freeze
      CODE_EXTENSIONS = %w[.rb .py .sh .bash .zsh .fish .js .mjs .cjs .ts .tsx .go .rs .lua .pl .php].freeze
      AI_SKIP = %w[.git node_modules projects backups .backup cache file-history paste-cache shell-snapshots session-env debug sessions tasks jobs plans
                   __pycache__ .specstory history plugins .tellem .scratch vendor telemetry tmp worktrees].freeze
      PLUGIN_SKIP = %w[.git node_modules .scratch .backup .specstory .tellem .tellem-wt __pycache__ worktrees docs specs references].freeze
      CONFIG_NAMES = /\A(?:.+\.rplugin\.yml|plugin\.json|hooks\.(?:json|yml)|config\.(?:yml|yaml|json|toml)|.+\.toml)\z/.freeze
      PLUGIN_SECONDS = 60
      TREE_ENTRIES = 60_000
      EVIDENCE_CAP = 6
      HOOK_FILES = 4

      module_function

      def collect(ctx, _deadline)
        readers = {}
        features(ctx).each { |reader| merge(readers, reader) }
        scripts(ctx).each { |reader| merge(readers, reader) }
        ai_files(ctx).each { |reader| merge(readers, reader) }
        plugins(ctx).each { |reader| merge(readers, reader) }
        Array(ctx.paths[:declared_readers]).each do |name|
          merge(readers, { "id" => "declared:#{name}", "kind" => "declared", "evidence" => [], "confidence" => "declared" })
        end
        readers.values.sort_by { |reader| reader["id"] }
      end

      def merge(readers, reader)
        known = readers[reader["id"]]
        if known.nil?
          readers[reader["id"]] = reader
        else
          known["evidence"] = (known["evidence"] + reader["evidence"]).uniq
          known["confidence"] = "confirmed" if reader["confidence"] == "confirmed"
        end
      end

      def features(ctx)
        %w[claude codex].flat_map do |harness|
          record = ctx.harness(harness)
          scan = ctx.scan(harness)
          Capabilities.features(harness).filter_map do |feature|
            resolved = Capabilities.resolve(feature.merge(kind: "feature"), record, scan)
            next if resolved["state"] == "absent"

            { "id" => "feature:#{harness}:#{feature[:name]}", "kind" => "harness_feature", "known_by" => resolved["known_by"],
              "evidence" => [{ "via" => "harness", "version" => record["version"] }.compact],
              "confidence" => resolved["state"] == "present" ? "confirmed" : "possible" }
          end
        end
      end

      def scripts(ctx)
        own = Bounds.real(Tellem.root.to_s)
        commands(ctx).flat_map do |command|
          candidates(command, ctx.paths).first(HOOK_FILES).filter_map do |path|
            next if own && Bounds.real(path).to_s.start_with?("#{own}/")

            text = Bounds.text(path, limit: Bounds::CODE_BYTES)
            next unless text

            hits = matches(text)
            reader_for(path, hits, "hook_command")
          end
        end
      end

      def commands(ctx)
        claude = ctx.claude_files.flat_map { |file| Cutover::Discover.entries(file["data"]).map(&:last) }
        codex = (ctx.codex_config || []).filter_map do |entry|
          entry[:value] if entry[:key] == "command" && entry[:section].first == "hooks" && entry[:section].last == "hooks" && entry[:value].is_a?(String)
        end
        (claude + codex).uniq
      end

      def candidates(command, paths)
        words = begin
          Shellwords.split(command)
        rescue ArgumentError
          command.split(/\s+/)
        end
        words.each_with_index.filter_map do |word, index|
          path = expand(word, paths[:home])
          path = on_path(word, paths[:path]) if index.zero? && !path.start_with?("/")
          path if path&.start_with?("/") && Bounds.stat(path)&.file?
        end.uniq
      end

      def expand(word, home)
        word.sub(/\A~(?=\/|\z)/, home).gsub(/\$\{?HOME\}?/, home)
      end

      def on_path(word, search)
        return nil if word.include?("/") || word.start_with?("-")

        search.to_s.split(File::PATH_SEPARATOR).map { |dir| File.join(dir, word) }.find { |path| Bounds.stat(path)&.file? }
      end

      def matches(text)
        PATTERNS.filter_map do |name, pattern|
          index = text.lines.index { |line| line.match?(pattern) }
          { "match" => name, "line" => index + 1 } if index
        end
      end

      def reader_for(path, hits, via)
        real = Bounds.real(path) || path
        base = { "path" => path, "via" => via }
        base["real_path"] = real if real != path
        evidence = hits.empty? ? [base] : hits.map { |hit| hit.merge(base) }
        { "id" => "script:#{real}", "kind" => "script", "evidence" => evidence.first(EVIDENCE_CAP), "confidence" => hits.empty? ? "possible" : "confirmed" }
      end

      def code?(path, text)
        CODE_EXTENSIONS.include?(File.extname(path).downcase) || CONFIG_NAMES.match?(File.basename(path)) ||
          (File.extname(path).empty? && text.start_with?("#!"))
      end

      def ai_files(ctx)
        ai_home = ctx.paths[:ai_home]
        return [] unless ai_home

        found = []
        real_home = Bounds.real(ai_home)
        Bounds.walk(real_home, deadline: Bounds.deadline(PLUGIN_SECONDS), skip: AI_SKIP, limit: TREE_ENTRIES) do |path, info|
          next if info.size > Bounds::CODE_BYTES || Bounds.refused?(path)

          text = Bounds.text(path, limit: Bounds::CODE_BYTES)
          next unless text && code?(path, text)

          hits = matches(text)
          found << reader_for(path.sub(real_home, ai_home), hits, "ai_home") unless hits.empty?
        end
        found
      rescue Exceeded => e
        found << { "id" => "scan:ai_home", "kind" => "scan", "evidence" => [], "confidence" => "unknown", "reason" => e.message }
      end

      def plugins(ctx)
        deadline = Bounds.deadline(PLUGIN_SECONDS)
        own = Bounds.real(Tellem.root.to_s)
        grouped = Plugins.all(ctx.paths).reject { |plugin| excluded?(plugin, own) }.group_by { |plugin| plugin["id"] }
        grouped.sort.map { |id, installs| scan_plugin(id, installs, deadline) }.reject { |reader| reader["confidence"] == "none" }
      end

      def excluded?(plugin, own)
        return true if Plugins.name_of(plugin["id"]) == PLUGIN

        real = Bounds.real(plugin["root"])
        real.nil? || (own && (real == own || real.start_with?("#{own}/")))
      end

      def scan_plugin(id, installs, deadline)
        evidence = []
        installs.each do |install|
          root = Bounds.real(install["root"])
          next unless root

          Bounds.walk(root, deadline: deadline, skip: PLUGIN_SKIP, limit: TREE_ENTRIES) do |path, info|
            next if info.size > Bounds::CODE_BYTES || evidence.size >= EVIDENCE_CAP

            text = Bounds.text(path, limit: Bounds::CODE_BYTES)
            next unless text && code?(path, text)

            matches(text).each do |hit|
              evidence << hit.merge("path" => path.delete_prefix("#{root}/"), "via" => install["source"]) if evidence.size < EVIDENCE_CAP
            end
          end
        end
        { "id" => "plugin:#{id}", "kind" => "plugin", "evidence" => evidence, "confidence" => evidence.empty? ? "none" : "confirmed" }
      rescue Exceeded => e
        { "id" => "plugin:#{id}", "kind" => "plugin", "evidence" => evidence, "confidence" => "unknown", "reason" => e.message }
      end
    end
  end
end
