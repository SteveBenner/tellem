# frozen_string_literal: true

require "json"
require_relative "../deriver/spool"
require_relative "../ids"
require_relative "../ingest/claude_bodies"
require_relative "../parity/bodies"
require_relative "../ports/harness_paths"
require_relative "../record/fs"
require_relative "../record/reader"
require_relative "ledger"
require_relative "liveness"
require_relative "state"
require_relative "switch"

module Tellem
  module Authority
    module Rehearse
      HARNESS = "claude"
      COMPARED = [Parity::Bodies::PARITY, Parity::Bodies::MISMATCH].freeze

      module_function

      def run(context, sessions, totals)
        return unless State.spool_owed?(HARNESS)
        return if Switch.off?

        dir = Ports::HarnessPaths.body_spool
        return unless Ingest::ClaudeBodies.unsafe_reason(dir).nil?

        sessions.each do |session|
          next unless session.harness == HARNESS && !session.failed

          process(context, session, dir, totals)
        rescue StandardError => e
          totals.errors << { "phase" => "rehearse", "session_key" => session.key, "error_class" => e.class.name, "message" => e.message[0, 200] }
        end
      end

      def process(context, session, dir, _totals)
        main = session.natives[Ids::MAIN_AGENT]
        return if main.nil? || Deriver::Spool.held?(session, main)
        return unless Liveness.over?(session)

        files = session_files(dir, session.session_id)
        return if files.empty?
        return unless settled?(session)

        version = session.batches.values.filter_map(&:harness_version).first
        row = Parity::Bodies.session_row(context, session.key, dir)
        Ledger.add(row, version || row["harness_version"]) if COMPARED.include?(row["verdict"])
        files.each { |path| Record::FS.unlink_quiet(path) }
      end

      def settled?(session)
        newest = session.all_raw.last&.fetch("ts", nil)
        session.overdue?(newest)
      end

      def session_files(dir, session_id)
        files = []
        named = {}
        Record::Reader.each(File.join(dir, Ingest::ClaudeBodies::INDEX)) do |line|
          named[File.basename(line["request_file"])] = true if line["request_file"].is_a?(String)
          next unless line["session_id"] == session_id

          files.concat(Ingest::ClaudeBodies.listed_files(dir, line))
        end
        files.concat(orphans(dir, session_id, named))
        files.select { |path| Record::FS.lstat(path)&.file? }.uniq
      end

      def orphans(dir, session_id, named)
        Dir.children(dir).select { |name| Ingest::ClaudeBodies::REQUEST_FILE.match?(name) && !named[name] && Liveness.owner(dir, name) == session_id }
           .map { |name| File.join(dir, name) }
      rescue SystemCallError
        []
      end
    end
  end
end
