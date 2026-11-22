# frozen_string_literal: true

require_relative "../ids"
require_relative "../errors"
require_relative "../record/fs"
require_relative "../record/scope"
require_relative "../record/writer"
require_relative "../entries/policy"
require_relative "../entries/withhold"
require_relative "sources"

module Tellem
  module Deriver
    module Transcripts
      INGEST = { "claude" => :ingest_claude, "codex" => :ingest_codex }.freeze
      LOSSY = "specstory_lossy"

      module_function

      def ingest(session)
        policy = Tellem::Entries::Policy.resolve(session.context)
        return policy_failed(session, policy) if policy.failed?

        reader = session.context.seam(INGEST.fetch(session.harness))
        read(session, reader, Ids::MAIN_AGENT, policy)
        if session.harness == "codex"
          Sources.codex_descendants(session) { |agent| read(session, reader, agent, policy) }
        else
          session.natives.keys.sort.each { |agent| read(session, reader, agent, policy) unless agent == Ids::MAIN_AGENT }
        end
        session.batches.each { |agent, batch| record_gaps(session, agent, batch) }
      rescue CapabilityUnavailable
        session.gap("ingest_unavailable", "transcript/#{session.key}", agent_key: Ids::MAIN_AGENT,
                                                                       ts: session.first_ts || Record::FS.rfc3339_ms(0))
      end

      def policy_failed(session, policy)
        session.gap("policy_failed", "transcript/#{session.key}:reason=#{policy.failure['reason']}", agent_key: Ids::MAIN_AGENT,
                                                                   ts: session.first_ts || Record::FS.rfc3339_ms(0), detail: policy.failure)
        session.failed = "transcripts"
      end

      def unrendered(context, scanned)
        return [] unless context.flag?("features.transcripts")

        taken = scanned.map(&:key)
        (Record::Scope.session_keys(context.root) - taken).filter_map do |key|
          natives = context.cursor.natives(key)
          next unless natives.any? { |agent, entry| Cursor.stat(entry["path"].to_s) && !rendered?(context, key, agent) }

          reopen(context, key)
        end
      end

      def rendered?(context, key, agent)
        name = context.cursor.rendered(key, agent)
        name.is_a?(String) && safe_name?(name) && Record::FS.lstat(File.join(Record::Scope.transcripts_dir(context.root, key), name))&.file?
      end

      def reopen(context, key)
        session = Session.new(context, key)
        Sources.load_raw(session)
        session.natives.merge!(Sources.discover(context, session.harness, session.session_id, Sources.main_path(session), session: session))
        session
      end

      def read(session, reader, agent, policy = nil)
        native = session.natives[agent]
        return unless native

        policy ||= Tellem::Entries::Policy.resolve(session.context)
        return if policy.failed?

        batch = reader.read(native["path"], session_id: session.session_id, agent_key: agent)
        session.batches[agent] = Tellem::Entries::Withhold.apply(batch, policy)
      end

      def record_gaps(session, agent, batch)
        ts = batch.started_at || session.first_ts
        return unless ts

        batch.gaps.each do |entry|
          session.gap(entry["cause"], entry["location"], agent_key: agent, ts: ts, detail: entry["detail"] || {},
                                                         count: entry["count"] || 1, harness_version: entry["harness_version"])
        end
      end

      def render(session)
        return {} unless session.context.flag?("features.transcripts")

        markdown = session.context.seam(:markdown)
        main = session.batches[Ids::MAIN_AGENT]
        rendered = {}
        session.batches.keys.sort.each do |agent|
          batch = session.batches[agent]
          frame = main || batch
          name = "#{markdown.filename(frame.started_at, frame.title, agent_id: agent == Ids::MAIN_AGENT ? nil : agent)}.md"
          text = markdown.render(session: info(session, frame), agent: { "agent_key" => agent, "agent_id" => batch.agent_id },
                                 exchanges: batch.exchanges)
          write(session, agent, name, text)
          rendered[agent] = name
        end
        rendered
      end

      def info(session, frame)
        { "harness" => session.harness, "session_id" => session.session_id, "started_at" => frame.started_at, "title" => frame.title }
      end

      def write(session, agent, name, text)
        dir = Record::Scope.transcripts_dir(session.root, session.key)
        path = File.join(dir, name)
        Record::Writer.replace_if_changed(path, text)
        previous = session.context.cursor.rendered(session.key, agent)
        Record::FS.unlink_quiet(File.join(dir, previous)) if previous.is_a?(String) && previous != name && safe_name?(previous)
        native = session.natives[agent]
        lossy = lossy_record(session, agent)
        record = session.add("transcript", agent_key: agent, ts: session.batches[agent].started_at || session.first_ts, body: {
                               "native_inode" => native["inode"], "native_size" => native["size"],
                               "path" => File.join("sessions", session.key, "transcripts", name),
                               "sha256" => Ids.sha256(text), "source" => Spool.held?(session, native) ? "bodies" : "native", "final" => session.stopped?
                             }, supersedes: lossy && lossy["id"])
        drop_lossy_copy(dir, lossy, name) if record && lossy
      end

      def lossy_record(session, agent)
        superseded = session.of("transcript").filter_map { |record| record["supersedes"] }
        session.of("transcript").find do |record|
          record["agent_key"] == agent && record["body"]["source"] == LOSSY && !superseded.include?(record["id"])
        end
      end

      def drop_lossy_copy(dir, lossy, name)
        previous = File.basename(lossy["body"]["path"].to_s)
        Record::FS.unlink_quiet(File.join(dir, previous)) if previous != name && safe_name?(previous)
      end

      def safe_name?(name)
        name.end_with?(".md") && !name.include?("/") && !name.start_with?(".")
      end
    end
  end
end
