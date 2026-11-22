# frozen_string_literal: true

require_relative "../cutover/apply"
require_relative "../ids"
require_relative "../parity/report"
require_relative "../record/fs"
require_relative "../record/reader"
require_relative "../record/scope"
require_relative "anchor"

module Tellem
  module Specstory
    module Verify
      IMPORT_SOURCE = "specstory_lossy"
      NOT_REPLACED_MARKDOWN = /\.md\z/.freeze

      module_function

      def import_gate
        applied = Cutover.latest_applied
        return nil unless applied && Cutover::History.wanted?(Cutover.load(applied["plan_id"]))

        job = Cutover::History.status(applied["plan_id"])
        state = job ? job["state"] : Cutover::History::NOT_STARTED
        state == Cutover::History::DONE ? nil : "history_import_#{state}"
      end

      def history(root, directory, names, plain:, gate:)
        return names.to_h { |name| [name, { "ok" => false, "reason" => gate }] } if gate

        copies = copies_index(root)
        parity = nil
        names.to_h do |name|
          unless NOT_REPLACED_MARKDOWN.match?(name)
            next [name, { "ok" => false, "reason" => "not_a_markdown_transcript" }]
          end

          sha = Ids.sha256(Record::FS.read(File.join(directory, name)))
          how = imported(root, copies, name, sha)
          if how.nil? && plain
            parity ||= parity_names(root)
            how = "parity" if parity[name]
          end
          [name, how ? { "ok" => true, "how" => how } : { "ok" => false, "reason" => "unverified_no_parity" }]
        end
      rescue SystemCallError, SymlinkRefused
        names.to_h { |name| [name, { "ok" => false, "reason" => "unreadable" }] }
      end

      def copies_index(root)
        index = Hash.new { |hash, key| hash[key] = [] }
        Record::Scope.session_keys(root).each do |key|
          dir = Record::Scope.transcripts_dir(root, key)
          next unless Record::FS.lstat(dir)&.directory?

          Dir.children(dir).each { |name| index[name] << key if NOT_REPLACED_MARKDOWN.match?(name) }
        end
        index
      end

      def imported(root, copies, name, sha)
        found = false
        copies[name].each do |key|
          copy = File.join(Record::Scope.transcripts_dir(root, key), name)
          next unless Record::FS.lstat(copy)&.file? && Ids.sha256(Record::FS.read(copy)) == sha

          found = true
          return "imported_with_receipt" if receipt?(root, key, name, sha)
        end
        found ? "record_copy" : nil
      end

      def receipt?(root, key, name, sha)
        hit = false
        Record::Reader.each(Record::Scope.derived_path(root, key)) do |record|
          body = record["body"]
          next unless record["kind"] == "transcript" && body.is_a?(Hash)

          hit ||= body["source"] == IMPORT_SOURCE && body["sha256"] == sha && body["path"].to_s.end_with?("/#{name}")
        end
        hit
      end

      def parity_names(root)
        history = Parity::History.new(root)
        return {} unless history.present?

        keys = Record::Scope.session_keys(root)
        known = keys.map { |key| key.split("-", 2).last }
        keys.each_with_object({}) do |key, out|
          result = Parity.transcripts(root, key, key.split("-", 2).last, history, known)
          next unless result["verdict"] == "match"

          result["agents"].each { |agent| out[agent["specstory"]] = true if agent["specstory"] && agent["verdict"] == "match" }
        end
      end
    end
  end
end
