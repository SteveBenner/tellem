# frozen_string_literal: true

require_relative "../ids"
require_relative "../ports/harness_paths"
require_relative "../record/fs"
require_relative "../record/reader"
require_relative "../record/registry"
require_relative "../record/scope"

module Tellem
  module Retention
    module Estimate
      COMPRESSED = "rollout-*.jsonl.zst"
      RECORD_DIRS = %w[transcripts entries].freeze

      module_function

      def run(harnesses)
        totals = { "bytes" => 0, "sessions" => 0, "record_bytes" => 0, "unreadable" => 0 }
        roots.each do |root|
          Record::Scope.session_keys(root).each do |key|
            harness, session_id = key.split("-", 2)
            next unless harnesses.include?(harness)

            add(totals, root, key, native_bytes(root, key, harness, session_id))
          end
        end
        totals["unreadable"] = Dir.glob(File.join(Ports::HarnessPaths.codex_sessions, "*", "*", "*", COMPRESSED)).size if harnesses.include?("codex")
        totals["share"] = totals["bytes"].zero? ? "0%" : "#{((totals['record_bytes'] * 100.0) / totals['bytes']).round(1)}%"
        totals
      end

      def roots
        Record::Registry.resolve.reject { |entry| entry["gone"] }.map { |entry| entry["root"].to_s }.uniq
      rescue SystemCallError
        []
      end

      def add(totals, root, key, bytes)
        return unless bytes.positive?

        totals["bytes"] += bytes
        totals["sessions"] += 1
        totals["record_bytes"] += record_bytes(root, key)
      end

      def native_bytes(root, key, harness, session_id)
        main = main_path(root, key)
        return 0 unless main && Record::FS.lstat(main)&.file?
        return File.lstat(main).size if harness == "codex"

        side = File.join(File.dirname(main), session_id)
        Dir.glob(File.join(side, "**", "*")).sum { |path| regular_size(path) } + File.lstat(main).size
      rescue SystemCallError
        0
      end

      def main_path(root, key)
        found = nil
        Record::Reader.each(File.join(Record::Scope.raw_dir(root, key), "#{Ids::MAIN_AGENT}.jsonl")) do |record|
          found = record["transcript_path"] if record["transcript_path"].is_a?(String) && record["transcript_path"].start_with?("/")
        end
        found
      rescue SystemCallError, SymlinkRefused
        nil
      end

      def regular_size(path)
        stat = Record::FS.lstat(path)
        stat&.file? ? stat.size : 0
      end

      def record_bytes(root, key)
        session = Record::Scope.session_dir(root, key)
        RECORD_DIRS.sum do |name|
          Dir.glob(File.join(session, name, "*")).sum { |path| regular_size(path) }
        end + regular_size(Record::Scope.derived_path(root, key))
      end
    end
  end
end
