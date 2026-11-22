# frozen_string_literal: true

require_relative "../record/fs"
require_relative "../record/reader"
require_relative "../record/scope"
require_relative "../deriver/sources"
require_relative "native"
require_relative "specstory"
require_relative "ledger"

module Tellem
  module Import
    class Presence
      PREFERENCE = %w[native specstory ledger].freeze
      TRANSCRIPT_SOURCES = { "native" => "native", "specstory_lossy" => "specstory", "ledger" => "ledger" }.freeze

      def initialize(harness)
        @harness = harness
        @native = {}
        @specstory = {}
        @ledger = {}
      end

      def sources(candidate)
        found = [candidate.source]
        found << "native" if native?(candidate)
        found << "specstory" if specstory?(candidate)
        found << "ledger" if ledger?(candidate)
        found.concat(existing(candidate))
        PREFERENCE.select { |source| found.include?(source) }
      end

      def native?(candidate)
        ids = @native[candidate.harness] ||= candidate.harness == "claude" ? Native.claude_ids(@harness) : Native.codex_ids(@harness)
        ids.key?(candidate.session_id)
      end

      def specstory?(candidate)
        (@specstory[candidate.home_root] ||= SpecStory.keys(candidate.home_root)).key?(candidate.session_key)
      end

      def ledger?(candidate)
        (@ledger[candidate.home_root] ||= Ledger.keys(candidate.home_root)).key?(candidate.session_key)
      end

      def existing(candidate)
        root = candidate.home_root
        key = candidate.session_key
        return [] unless Record::FS.lstat(Record::Scope.dir(root))&.directory?

        found = []
        found << "native" unless Deriver::Sources.raw_files(root, key).empty?
        Record::Reader.each(Record::Scope.derived_path(root, key)) do |record|
          body = record["body"].is_a?(Hash) ? record["body"] : {}
          case record["kind"]
          when "transcript" then found << TRANSCRIPT_SOURCES.fetch(body["source"], "native")
          when "usage" then found << (body["source"] == Ledger::SOURCE ? "ledger" : "native")
          end
        end
        found.uniq
      end
    end
  end
end
