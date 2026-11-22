# frozen_string_literal: true

require "json"
require_relative "../authority/switch"
require_relative "../ids"
require_relative "../ingest/claude_bodies"
require_relative "../ingest/support"
require_relative "../ports/harness_paths"
require_relative "../record/fs"
require_relative "../record/reader"
require_relative "../record/scope"
require_relative "cursor"

module Tellem
  module Deriver
    module Spool
      HARNESS = "claude"
      ENTRY = "bodies/index"
      HELD_DIR = "bodies"
      SIDEBAND_FILE = "sideband.jsonl"
      UNSAFE = Ingest::ClaudeBodies::UNSAFE

      module_function

      def dir
        Ports::HarnessPaths.body_spool
      end

      def held_dir(root, key)
        File.join(Record::Scope.session_dir(root, key), HELD_DIR)
      end

      def held_path(root, key, agent)
        File.join(held_dir(root, key), "#{agent}.jsonl")
      end

      def held?(session, native)
        return false unless native.is_a?(Hash)

        File.dirname(native["path"].to_s) == held_dir(session.root, session.key)
      end

      def unsafe_reason(path)
        Ingest::ClaudeBodies.unsafe_reason(path)
      end

      def changed?(context, key)
        return false unless key.start_with?("#{HARNESS}-")

        native = context.cursor.natives(key)[Ids::MAIN_AGENT]
        return false if native && File.dirname(native["path"].to_s) != held_dir(context.root, key)

        session_id = key.split("-", 2).last
        count = index_counts(context)[session_id].to_i
        return false if count.zero?

        count != context.cursor.raw(key, ENTRY)&.fetch("records", 0).to_i
      end

      def index_counts(context)
        return @counts if @counted_for.equal?(context)

        counts = Hash.new(0)
        if unsafe_reason(dir).nil?
          Record::Reader.each(File.join(dir, Ingest::ClaudeBodies::INDEX)) do |line|
            counts[line["session_id"]] += 1 if line["session_id"].is_a?(String)
          end
        end
        @counted_for = context
        @counts = counts
      end

      def attach(session)
        return unless session.harness == HARNESS

        main = session.natives[Ids::MAIN_AGENT]
        return if main && !held?(session, main)

        ingest(session)
        attach_held(session)
      rescue SystemCallError, IOError, JSON::GeneratorError, EncodingError => e
        session.gap("spool_error", "bodies/#{e.class.name}", agent_key: Ids::MAIN_AGENT, ts: session.first_ts || Record::FS.rfc3339_ms(0),
                                                             detail: { "error_class" => e.class.name })
        attach_held(session)
      end

      def ingest(session)
        path = dir
        reason = unsafe_reason(path)
        if reason
          return if reason == "missing"

          session.gap(UNSAFE, "bodies/#{reason}", agent_key: Ids::MAIN_AGENT, ts: session.first_ts || Record::FS.rfc3339_ms(0), detail: { "reason" => reason })
          return
        end

        held, done = held_lines(session)
        evidence = Ingest::ClaudeBodies::Evidence.new(session.raw)
        version = harness_version(session)
        view = Ingest::ClaudeBodies.view(path, session_id: session.session_id, evidence: evidence, held: held, done: done, version: version,
                                               ready: ->(ts) { session.overdue?(ts) }, final: session.stopped?)
        record_gaps(session, view, version)
        persist(session, view)
        remove(view.ingested) unless Authority::Switch.off?
        session.raw_entries[ENTRY] = { "records" => view.mine }
      end

      def harness_version(session)
        Sources.safe(session, "harness_version") { session.context.harness.harness_version(HARNESS) }
      end

      def held_lines(session)
        folder = held_dir(session.root, session.key)
        return [{}, {}] unless Record::FS.lstat(folder)&.directory?

        lines = {}
        done = {}
        Dir.children(folder).sort.each do |name|
          next unless name.end_with?(".jsonl")

          agent = name.delete_suffix(".jsonl")
          Record::Reader.each(File.join(folder, name)) do |line|
            done[line["bodyRequest"]] = true if line["bodyRequest"].is_a?(String)
            (lines[agent] ||= []) << line unless name == SIDEBAND_FILE
          end
        end
        [lines, done]
      end

      def record_gaps(session, view, version)
        view.gaps.each do |entry|
          session.gap(entry["cause"], "bodies/#{entry['suffix']}", agent_key: Ids::MAIN_AGENT, ts: session.first_ts || Record::FS.rfc3339_ms(0),
                                                                   detail: entry["detail"], count: entry["count"], harness_version: version)
        end
      end

      def persist(session, view)
        return if view.agents.empty? && view.sideband.empty?

        Record::FS.mkdir_p(held_dir(session.root, session.key))
        view.agents.each { |agent, lines| commit(held_path(session.root, session.key, agent), lines.map { |line| redact(line) }) }
        commit(File.join(held_dir(session.root, session.key), SIDEBAND_FILE), view.sideband) unless view.sideband.empty?
      end

      def commit(path, lines)
        return if lines.empty?

        existing = Record::FS.lstat(path) ? Record::Reader.records(path).first : []
        merged = (existing + lines).each_with_index.sort_by { |line, index| [line["timestamp"].to_s, index] }.map(&:first)
        Record::FS.replace(path, merged.map { |line| "#{JSON.generate(line)}\n" }.join)
      end

      def redact(line)
        message = line["message"]
        return line unless message.is_a?(Hash) && message["content"].is_a?(Array)

        line.merge("message" => message.merge("content" => message["content"].map { |block| redact_block(block) }))
      end

      def redact_block(block)
        case block["type"]
        when "text" then block.merge("text" => Redact.text(block["text"].to_s))
        when "tool_use", "server_tool_use" then block.merge("input" => Ingest::Support.deep(block["input"]))
        when "tool_result" then block.merge("content" => redact_content(block["content"]))
        else Ingest::Support.deep(block)
        end
      end

      def redact_content(content)
        case content
        when String then Redact.text(content)
        when Array then content.map { |part| part.is_a?(Hash) && part["text"].is_a?(String) ? part.merge("text" => Redact.text(part["text"])) : part }
        else content
        end
      end

      def remove(requests)
        requests.flat_map { |request| request["files"] }.each { |path| Record::FS.unlink_quiet(path) }
      end

      def attach_held(session)
        folder = held_dir(session.root, session.key)
        return unless Record::FS.lstat(folder)&.directory?

        Dir.children(folder).sort.each do |name|
          next if !name.end_with?(".jsonl") || name == SIDEBAND_FILE

          agent = name.delete_suffix(".jsonl")
          stat = Cursor.stat(File.join(folder, name))
          session.natives[agent] = stat if stat && Ids.valid_agent_key?(agent)
        end
      end
    end
  end
end
