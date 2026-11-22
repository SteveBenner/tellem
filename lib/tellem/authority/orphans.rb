# frozen_string_literal: true

require_relative "../config/resolver"
require_relative "../ids"
require_relative "../ingest/claude_bodies"
require_relative "../ports/harness_paths"
require_relative "../record/fs"
require_relative "../record/reader"
require_relative "liveness"
require_relative "state"
require_relative "switch"

module Tellem
  module Authority
    module Orphans
      GAP = "spool_orphan"
      DAY_S = 86_400
      DEFAULT_DAYS = 14

      module_function

      def run(root, sessions, totals)
        return if Switch.off?

        dir = Ports::HarnessPaths.body_spool
        return unless Ingest::ClaudeBodies.unsafe_reason(dir).nil?

        sessions.each do |session|
          next unless session.harness == "claude" && !session.failed && Liveness.over?(session)

          sweep(root, session, dir, totals)
        end
      rescue SystemCallError => e
        totals.errors << { "phase" => "orphans", "error_class" => e.class.name }
      end

      def sweep(root, session, dir, totals)
        files = stale(root, session.session_id, dir)
        return if files.empty?

        files.each { |path| Record::FS.unlink_quiet(path) }
        session.gap(GAP, "bodies/#{Record::FS.now_ns}", agent_key: Ids::MAIN_AGENT, ts: session.first_ts || Record::FS.rfc3339_ms(0),
                                                        detail: { "files" => files.size }, count: files.size)
        totals.absorb(session.flush)
      end

      def stale(root, session_id, dir)
        cutoff = Record::FS.now_ns - (window_s(root) * State::NS)
        named = {}
        Record::Reader.each(File.join(dir, Ingest::ClaudeBodies::INDEX)) { |line| named[File.basename(line["request_file"])] = true if line["request_file"].is_a?(String) }
        Dir.children(dir).filter_map do |name|
          next unless Ingest::ClaudeBodies::REQUEST_FILE.match?(name) && !named[name] && Liveness.owner(dir, name) == session_id

          path = File.join(dir, name)
          path if (File.lstat(path).mtime.to_r * State::NS).to_i < cutoff
        end
      end

      def window_s(root)
        days = Config.get("retention.native_days", scope: root)
        (days.is_a?(Integer) && days >= 0 ? days : DEFAULT_DAYS) * DAY_S
      rescue UsageError
        DEFAULT_DAYS * DAY_S
      end
    end
  end
end
