# frozen_string_literal: true

require "json"
require_relative "../record/fs"
require_relative "../record/reader"
require_relative "state"

module Tellem
  module Authority
    module Ledger
      SCHEMA = "tellem.body-parity/v1"

      module_function

      def file
        File.join(State.dir, "body-parity.jsonl")
      end

      def add(row, version)
        Record::FS.mkdir_p(State.dir)
        causes = Array(row["causes"]).map { |cause| cause["cause"] }
        line = { "schema" => SCHEMA, "at" => Record::FS.rfc3339, "harness" => "claude", "harness_version" => version, "session_key" => row["session_key"],
                 "scope_root" => row["scope_root"], "verdict" => row["verdict"], "causes" => causes.tally.sort.to_h,
                 "agents" => Array(row["agents"]).map { |agent| agent.slice("agent_key", "verdict", "turns", "requests", "tools") },
                 "requests" => row["requests"] }.compact
        handle = Record::FS.open_append(file)
        begin
          handle.flock(File::LOCK_EX)
          Record::FS.write_all(handle, "#{JSON.generate(line)}\n")
          handle.fsync
        ensure
          handle.close
        end
        line
      end

      def rows
        return [] unless Record::FS.lexists?(file)

        Record::Reader.records(file).first.select { |row| row["schema"] == SCHEMA }
      end

      def known?(session_key)
        rows.any? { |row| row["session_key"] == session_key }
      end

      def at(version)
        rows.select { |row| row["harness_version"] == version }
      end

      def causes(version)
        at(version).flat_map { |row| row["causes"].keys }.uniq.sort
      end

      def versions
        rows.map { |row| row["harness_version"] }.compact.uniq.sort
      end
    end
  end
end
