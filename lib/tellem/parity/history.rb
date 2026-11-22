# frozen_string_literal: true

require_relative "../errors"
require_relative "../record/fs"
require_relative "../record/scope"

module Tellem
  module Parity
    class History
      DIR = File.join(".specstory", "history")
      SUBAGENT = "--subagent-"
      HEADER_BYTES = 2048
      SESSION_HEADER = /Session ([A-Za-z0-9_-]{1,200}) \(/
      MARKDOWN = /\A[^\/]+\.md\z/
      NAMED_SUBAGENT = /\A(?<base>\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}[+-]\d{4}-(?<harness>claude|codex)-(?<prefix>[0-9a-f][0-9a-f-]{7,35}))#{SUBAGENT}(?<agent>[A-Za-z0-9_-]{1,128})\.md\z/.freeze
      FULL_ID = 36

      attr_reader :dir, :problem

      def initialize(root)
        @dir = File.join(root, DIR)
        @names = nil
        @heads = nil
        @problem = nil
        load_names
      end

      def present?
        !@names.nil? && !@names.empty?
      end

      def names
        @names || []
      end

      def read(name)
        Record::FS.read(File.join(dir, name))
      rescue SystemCallError, SymlinkRefused
        nil
      end

      def main_for(session_id, tellem_main)
        return tellem_main if tellem_main && names.include?(tellem_main)

        heads[session_id]
      end

      def subagents_of(main_name, harness: nil, session_id: nil, known: [])
        base = main_name.delete_suffix(".md")
        prefix = "#{base}#{SUBAGENT}"
        found = names.select { |name| name.start_with?(prefix) }.to_h { |name| [name.delete_prefix(prefix).delete_suffix(".md"), name] }
        return found unless harness && session_id

        names.each do |name|
          named = NAMED_SUBAGENT.match(name)
          next unless named && named[:harness] == harness && !found.key?(named[:agent]) && !names.include?("#{named[:base]}.md")

          found[named[:agent]] = name if resolve(named[:prefix], known) == session_id
        end
        found
      end

      def resolve(prefix, known)
        return prefix if prefix.size == FULL_ID

        unique_prefix(heads.keys, prefix) || unique_prefix(known, prefix)
      end

      def unique_prefix(ids, prefix)
        matches = ids.select { |id| id.start_with?(prefix) }.uniq
        matches.size == 1 ? matches.first : nil
      end

      private

      def load_names
        [File.dirname(dir), dir].each do |path|
          stat = Record::FS.lstat(path)
          return if stat.nil?

          if stat.symlink?
            @problem = "specstory_symlink_refused"
            return
          end
          return unless stat.directory?
        end
        @names = Dir.children(dir).select { |name| MARKDOWN.match?(name) && Record::FS.lstat(File.join(dir, name))&.file? }.sort
      rescue SystemCallError
        @names = nil
      end

      def heads
        @heads ||= names.reject { |name| name.include?(SUBAGENT) }.each_with_object({}) do |name, out|
          head = header(name)
          match = head && SESSION_HEADER.match(head)
          out[match[1]] ||= name if match
        end
      end

      def header(name)
        Record::FS.open_read(File.join(dir, name)) { |file| file.read(HEADER_BYTES) }
      rescue SystemCallError, SymlinkRefused
        nil
      end
    end
  end
end
