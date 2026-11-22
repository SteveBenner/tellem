# frozen_string_literal: true

require "date"
require "time"
require_relative "../errors"
require_relative "../ids"
require_relative "../otel/settings"
require_relative "../record/formats"
require_relative "../record/reader"
require_relative "../record/scope"
require_relative "cursor"
require_relative "session"
require_relative "spool"

module Tellem
  module Deriver
    module Sources
      SUBAGENT_FILE = /\Aagent-(?<id>[A-Za-z0-9_-]{1,128})\.jsonl\z/
      OUTSIDE_FAILURES = [SystemCallError, IOError].freeze
      PORT_FAILURES = %w[Rplugin::PortUnavailable Rplugin::Ports::NotHandled].freeze
      UNREADABLE = "harness_unreadable"

      class HarnessUnreadable < OperationalFailure
      end

      module_function

      def scan(context)
        Record::Scope.session_keys(context.root).filter_map do |key|
          next unless touched?(context, key)

          session = Session.new(context, key)
          load_raw(session)
          session.natives.merge!(discover(context, session.harness, session.session_id, main_path(session), session: session))
          Spool.attach(session)
          session
        end
      end

      def main_path(session)
        found = main_transcript(session)
        prior = session.context.cursor.natives(session.key).dig(Ids::MAIN_AGENT, "path")
        return prior if found.nil?
        return prior if Cursor.stat(found).nil? && Spool.held?(session, { "path" => prior })

        found
      end

      def raw_files(root, key)
        dir = Record::Scope.raw_dir(root, key)
        Dir.children(dir).filter_map do |name|
          agent = name.delete_suffix(".jsonl")
          [agent, File.join(dir, name)] if name.end_with?(".jsonl") && Ids.valid_agent_key?(agent)
        end.sort
      rescue SystemCallError
        []
      end

      def touched?(context, key)
        cursor = context.cursor
        return true if cursor.session(key).empty? || cursor.session(key)["unsettled"] == true

        raw_files(context.root, key).each do |agent, path|
          prior = cursor.raw(key, agent)
          stat = Cursor.stat(path)
          return true if prior.nil? || stat.nil? || stat["inode"] != prior["inode"] || stat["size"] != prior["offset"]
        end
        spool_changed?(context, key) || Spool.changed?(context, key) || natives_changed?(context, key)
      end

      def spool_changed?(context, key)
        stat = Cursor.stat(Otel::Settings.spool(key))
        return false if stat.nil?

        prior = context.cursor.raw(key, Otel::Settings::SPOOL_ENTRY)
        prior.nil? || stat["inode"] != prior["inode"] || stat["size"] != prior["offset"]
      end

      def natives_changed?(context, key)
        prior = context.cursor.natives(key)
        prior.each_value do |entry|
          current = Cursor.stat(entry["path"].to_s)
          next if current.nil?
          return true if %w[inode size mtime_ns].any? { |field| current[field] != entry[field] }
        end
        harness, session_id = key.split("-", 2)
        main = prior.dig(Ids::MAIN_AGENT, "path")
        known = prior.values.map { |entry| entry["path"] }
        discover(context, harness, session_id, main).any? { |_agent, entry| !known.include?(entry["path"]) }
      rescue HarnessUnreadable
        true
      end

      def load_raw(session)
        cursor = session.context.cursor
        raw_files(session.root, session.key).each do |agent, path|
          records, read = Record::Reader.records(path)
          valid = records.select { |record| valid_raw?(record) }.sort_by { |record| [record["ts"], record["id"]] }
          session.raw[agent] = valid
          session.raw_paths[agent] = path
          session.raw_entries[agent] = { "inode" => read["inode"], "offset" => read["offset"], "records" => valid.size }
          session.fresh.concat(fresh(cursor.raw(session.key, agent), read, valid))
          raw_gaps(session, agent, read["torn"].to_i, records.size - valid.size, valid.first || records.first)
        end
        session.fresh.sort_by! { |record| [record["ts"], record["id"]] }
      end

      def fresh(prior, read, valid)
        return valid unless prior && prior["inode"] == read["inode"] && prior["offset"].to_i <= read["offset"].to_i

        valid.drop(prior["records"].to_i)
      end

      def valid_raw?(record)
        record["schema"] == Record::Schemas::RAW && record["id"].is_a?(String) &&
          record["ts"].is_a?(String) && Record::Formats::RFC3339_MS.match?(record["ts"]) &&
          Record::Formats::RAW_EVENTS.include?(record["event"])
      end

      def raw_gaps(session, agent, torn, invalid, first)
        ts = first.is_a?(Hash) && first["ts"].is_a?(String) && Record::Formats::RFC3339_MS.match?(first["ts"]) ? first["ts"] : nil
        ts ||= Record::FS.rfc3339_ms(0)
        location = "raw/#{agent}"
        session.gap("torn_line", location, agent_key: agent, ts: ts, detail: { "lines" => torn }, count: torn) if torn.positive?
        session.gap("invalid_raw", location, agent_key: agent, ts: ts, detail: { "lines" => invalid }, count: invalid) if invalid.positive?
      end

      def main_transcript(session)
        main = session.raw[Ids::MAIN_AGENT].to_a + session.all_raw
        found = main.reverse.find { |record| record["transcript_path"].is_a?(String) && record["transcript_path"].start_with?("/") }
        found && found["transcript_path"]
      end

      def discover(context, harness, session_id, main_path, session: nil)
        found = {}
        main = main_path && Cursor.stat(main_path)
        if harness == "codex"
          main ||= Array(safe(session, "codex_rollouts") { context.harness.codex_rollouts(session_id: session_id) }).filter_map { |path| Cursor.stat(path) }.last
          found[Ids::MAIN_AGENT] = main if main
          return found
        end
        return found unless main

        found[Ids::MAIN_AGENT] = main
        Array(safe(session, "claude_subagent_transcripts") { context.harness.claude_subagent_transcripts(main["path"], session_id) }).each do |path|
          match = SUBAGENT_FILE.match(File.basename(path))
          stat = match && Cursor.stat(path)
          agent = match && Ids.agent_key(match[:id])
          found[agent] = stat if stat && agent && agent != Ids::MAIN_AGENT
        end
        found
      end

      def codex_descendants(session)
        heads = {}
        queue = [Ids::MAIN_AGENT]
        seen = [session.session_id]
        while (agent = queue.shift)
          batch = session.batches[agent]
          next unless batch

          thread = batch.thread_id || (agent == Ids::MAIN_AGENT ? session.session_id : agent)
          seen << thread
          codex_child_paths(session, batch, thread, heads).each do |child, path|
            key = Ids.agent_key(child)
            next if key.nil? || key == Ids::MAIN_AGENT || session.natives.key?(key) || seen.include?(child)

            stat = Cursor.stat(path)
            next unless stat

            session.natives[key] = stat
            yield key
            queue << key
          end
        end
      end

      def codex_child_paths(session, batch, thread, heads)
        found = {}
        Array(batch.subagents).each do |link|
          id = link["agent_id"]
          path = id && Array(safe(session, "codex_rollouts") { session.context.harness.codex_rollouts(session_id: id) }).last
          found[id] ||= path if path
        end
        codex_days(session).each do |day|
          heads[day] ||= Array(safe(session, "codex_thread_heads") { session.context.harness.codex_thread_heads(day) })
          heads[day].each do |head|
            found[head["id"]] ||= head["path"] if head["id"] && head["parent_thread_id"] == thread && head["id"] != thread
          end
        end
        found
      end

      def codex_days(session)
        times = session.batches.values.flat_map { |batch| [batch.started_at] + batch.exchanges.map { |exchange| exchange["ts"] } + batch.usage.map { |entry| entry["ts"] } }
        times = times.grep(String).filter_map { |ts| local_day(ts) }
        return [] if times.empty?

        (times.min..times.max).to_a
      end

      def local_day(ts)
        Time.iso8601(ts).localtime.to_date
      rescue ArgumentError
        nil
      end

      def outside_failures
        OUTSIDE_FAILURES + PORT_FAILURES.filter_map { |name| Object.const_get(name) if Object.const_defined?(name) }
      end

      def safe(session, call)
        yield
      rescue *outside_failures => e
        unless session.respond_to?(:gap)
          raise HarnessUnreadable.new("the harness #{call} lookup failed: #{e.class.name}", detail: { "call" => call, "error_class" => e.class.name })
        end

        session.gap(UNREADABLE, "harness/#{call}", agent_key: Ids::MAIN_AGENT, ts: session.first_ts || Record::FS.rfc3339_ms(0),
                                                    detail: { "error_class" => e.class.name })
        nil
      end
    end
  end
end
