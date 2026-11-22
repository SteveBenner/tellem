# frozen_string_literal: true

require "time"
require_relative "../errors"
require_relative "../ids"
require_relative "../record/fs"
require_relative "../record/scope"
require_relative "../record/writer"
require_relative "../deriver/cursor"
require_relative "candidate"
require_relative "files"
require_relative "native"
require_relative "ledger"

module Tellem
  module Import
    module SpecStory
      SOURCE = "specstory"
      LABEL = "specstory_lossy"
      HISTORY = File.join(".specstory", "history")
      NAME = /\A(?<base>\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}[+-]\d{4}(?:-[^\/]*?)?)(?:--subagent-(?<agent>[A-Za-z0-9_-]{1,128}))?\.md\z/
      HEADER = /<!-- (?<label>[^\n]*?) Session (?<id>[A-Za-z0-9_-]{1,200}) \((?<time>[^)\n]*)\) -->/
      HARNESSES = { "Claude Code" => "claude", "Codex CLI" => "codex", "Codex" => "codex" }.freeze
      HEADER_TIME = "%Y-%m-%d %H:%M:%S%z"
      NAME_TIME = "%Y-%m-%d_%H-%M-%S%z"
      NAMED = /\A\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}[+-]\d{4}-(?<harness>claude|codex)-(?<id>[0-9a-f][0-9a-f-]{7,35})\z/.freeze
      FULL_ID = 36
      MISSING_MAIN = "missing_main_transcript"

      MainId = Struct.new(:label, :session_id, keyword_init: true)
      Parsed = Struct.new(:path, :name, :base, :agent, :label, :session_id, :started_at, keyword_init: true)

      module_function

      def candidates(paths, harness, skipped)
        found = {}
        known = {}
        files(paths).group_by { |path| File.dirname(path) }.sort.each do |dir, list|
          parsed = list.sort.filter_map { |path| parse(path, skipped) }
          all_mains = parsed.reject(&:agent)
          mains = all_mains.group_by(&:base)
          parsed.each do |file|
            named = file.agent && mains[file.base].nil? ? NAMED.match(file.base) : nil
            if named
              lookup = ->(name, root) { known[[name, root]] ||= native_ids(harness, name).keys + scope_ids(root, name) }
              add_named(found, dir, file, named, all_mains, lookup, skipped)
            else
              add(found, dir, file, mains[file.base], skipped)
            end
          end
        end
        found.values
      end

      def native_ids(harness, name)
        name == "claude" ? Native.claude_ids(harness) : Native.codex_ids(harness)
      end

      def add_named(found, dir, file, named, mains, lookup, skipped)
        harness = named[:harness]
        session_id = resolve(named[:id], harness, mains) || unique_prefix(lookup.call(harness, Record::Scope.locate(dir)), named[:id])
        return skip(skipped, file.path, "unresolved_session") unless session_id

        key = Ids.session_key(harness, session_id)
        return skip(skipped, file.path, "invalid_session_id") unless key

        agent = Ids.agent_key(file.agent)
        return skip(skipped, file.path, "invalid_agent_id") unless agent

        main = mains.find { |item| HARNESSES[item.label] == harness && item.session_id == session_id }
        item(found, key, harness, session_id, dir, main ? main.started_at : file.started_at, file, agent, skipped)
      end

      def scope_ids(root, harness)
        prefix = "#{harness}-"
        sessions = Record::Scope.sessions_dir(root)
        stored = File.directory?(sessions) ? Dir.children(sessions) : []
        (Ledger.keys(root).keys + stored).select { |key| key.start_with?(prefix) }.map { |key| key.delete_prefix(prefix) }
      end

      def resolve(id, harness, mains)
        return id if id.size == FULL_ID && Ids.session_key(harness, id)

        unique_prefix(mains.select { |main| HARNESSES[main.label] == harness }.map(&:session_id), id)
      end

      def unique_prefix(ids, prefix)
        matches = ids.select { |id| id.start_with?(prefix) }.uniq
        matches.size == 1 ? matches.first : nil
      end

      def files(paths)
        return markdown(File.join(Record::Scope.locate(Dir.pwd), HISTORY)) if paths.empty?

        paths.flat_map do |path|
          if Files.regular?(path)
            [path]
          elsif File.directory?(File.join(path, HISTORY))
            markdown(File.join(path, HISTORY))
          elsif File.directory?(path)
            markdown(path)
          else
            raise UsageError.new("no file or directory at #{path}", next_command: "tellem import specstory --path PATH")
          end
        end.uniq
      end

      def markdown(dir)
        Dir.glob(File.join(dir, "*.md")).select { |path| Files.regular?(path) }.sort
      end

      def parse(path, skipped)
        match = NAME.match(File.basename(path))
        return skip(skipped, path, "not_a_specstory_name") unless match

        header = HEADER.match(Files.head(path))
        return skip(skipped, path, "no_session_header") unless header

        Parsed.new(path: path, name: File.basename(path), base: match[:base], agent: match[:agent], label: header[:label],
                   session_id: header[:id], started_at: started_at(header[:time], match[:base]))
      end

      def add(found, dir, file, mains, skipped)
        return skip(skipped, file.path, file.agent ? "no_main_file" : "duplicate_main_file") unless mains&.size == 1

        main = mains.first
        harness = HARNESSES[main.label]
        return skip(skipped, file.path, "unsupported_harness") unless harness

        key = Ids.session_key(harness, main.session_id)
        return skip(skipped, file.path, "invalid_session_id") unless key

        agent = file.agent ? Ids.agent_key(file.agent) : Ids::MAIN_AGENT
        return skip(skipped, file.path, "invalid_agent_id") unless agent

        item(found, key, harness, main.session_id, dir, main.started_at, file, agent, skipped)
      end

      def item(found, key, harness, session_id, dir, started_at, file, agent, skipped)
        candidate = found[key] ||= Candidate.new(session_key: key, harness: harness, session_id: session_id,
                                                 home_root: Homes.root_for(key, dir), source: SOURCE, files: [],
                                                 data: { "started_at" => started_at, "items" => [] })
        candidate.data["started_at"] = started_at if agent == Ids::MAIN_AGENT && started_at
        return skip(skipped, file.path, "duplicate_agent_file") if duplicate?(candidate, file, agent)

        candidate.files << file.path
        candidate.data["items"] << { "path" => file.path, "name" => file.name, "agent_key" => agent,
                                     "started_at" => file.started_at || started_at }
      end

      def duplicate?(candidate, file, agent)
        same = candidate.data["items"].select { |item| item["agent_key"] == agent }
        return false if same.empty?

        same.map { |item| Ids.sha256(Files.read(item["path"])) }.include?(Ids.sha256(Files.read(file.path)))
      end

      def started_at(header_time, base)
        Files.utc_ms(Time.strptime(header_time, HEADER_TIME))
      rescue ArgumentError
        begin
          Files.utc_ms(Time.strptime(base[0, 24], NAME_TIME))
        rescue ArgumentError
          nil
        end
      end

      def keys(root)
        mains = []
        named = []
        markdown(File.join(root, HISTORY)).each do |path|
          match = NAME.match(File.basename(path))
          next unless match

          if match[:agent].nil?
            header = HEADER.match(Files.head(path))
            mains << header if header && HARNESSES[header[:label]]
          elsif (found = NAMED.match(match[:base]))
            named << found
          end
        end
        out = mains.each_with_object({}) do |header, keys|
          key = Ids.session_key(HARNESSES[header[:label]], header[:id])
          keys[key] = true if key
        end
        main_ids = mains.map { |header| MainId.new(label: header[:label], session_id: header[:id]) }
        named.each do |found|
          id = resolve(found[:id], found[:harness], main_ids)
          key = id && Ids.session_key(found[:harness], id)
          out[key] = true if key
        end
        out
      end

      def apply(context, candidates, totals)
        candidates.each do |candidate|
          session = Deriver::Session.new(context, candidate.session_key)
          started = candidate.data["started_at"] || candidate.data["items"].filter_map { |item| item["started_at"] }.min
          Records.session(session, candidate, started) if started
          candidate.data["items"].each { |item| transcript(session, candidate, item, started) }
          missing_main(session, candidate, started)
          totals.session(session.key)
          totals.absorb(session.flush)
        end
      end

      def transcript(session, candidate, item, started)
        bytes = Files.read(item["path"])
        stat = Deriver::Cursor.stat(item["path"])
        raise OperationalFailure.new("source vanished during import: #{item['path']}") unless stat

        target = File.join(Record::Scope.transcripts_dir(session.root, candidate.session_key), item["name"])
        Record::Writer.replace_if_changed(target, bytes)
        session.add("transcript", agent_key: item["agent_key"], ts: item["started_at"] || started || Record::FS.rfc3339_ms(0), body: {
                      "native_inode" => stat["inode"], "native_size" => stat["size"],
                      "path" => File.join("sessions", candidate.session_key, "transcripts", item["name"]),
                      "sha256" => Ids.sha256(bytes), "source" => LABEL, "final" => true
                    })
      end

      def missing_main(session, candidate, started)
        items = candidate.data["items"]
        return if items.any? { |item| item["agent_key"] == Ids::MAIN_AGENT }

        session.gap(MISSING_MAIN, "specstory/#{Ids::MAIN_AGENT}", agent_key: Ids::MAIN_AGENT,
                                                                 ts: started || Record::FS.rfc3339_ms(0),
                                                                 detail: { "subagent_files" => items.size }, count: 1)
      end

      def skip(skipped, path, cause)
        skipped << { "path" => path, "cause" => cause }
        nil
      end
    end
  end
end
