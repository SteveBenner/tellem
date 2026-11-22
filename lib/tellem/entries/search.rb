# frozen_string_literal: true

require_relative "../ids"
require_relative "../record/fs"
require_relative "../record/scope"

module Tellem
  module Entries
    module Search
      SUBAGENT = /--subagent-([A-Za-z0-9_-]+)\.md\z/.freeze
      EXCERPT_BYTES = 200
      QUERY_BYTES = 256
      MAX_FILE_BYTES = 268_435_456

      module_function

      def run(scopes, query, limit:)
        pattern = Regexp.new(Regexp.escape(query), Regexp::IGNORECASE)
        matches = []
        truncated = false
        scopes.each do |scope|
          root = scope["root"]
          Record::Scope.session_keys(root).each do |key|
            files(root, key).each do |path, agent|
              scan(path, pattern) do |number, excerpt|
                if matches.size >= limit
                  truncated = true
                  next
                end
                matches << { "scope_root" => root, "session_key" => key, "agent_key" => agent, "file" => relative(root, path),
                             "line" => number, "excerpt" => excerpt }
              end
            end
          end
        end
        { "query" => query, "scopes" => scopes.size, "matches" => matches, "truncated" => truncated }
      end

      def files(root, key)
        dir = Record::Scope.transcripts_dir(root, key)
        stat = Record::FS.lstat(dir)
        return [] unless stat&.directory?

        Dir.children(dir).sort.filter_map do |name|
          next unless name.end_with?(".md") && !name.start_with?(".")

          path = File.join(dir, name)
          file = Record::FS.lstat(path)
          [path, name[SUBAGENT, 1] || Ids::MAIN_AGENT] if file&.file? && file.size <= MAX_FILE_BYTES
        end
      rescue SystemCallError
        []
      end

      def scan(path, pattern)
        Record::FS.open_read(path) do |file|
          number = 0
          file.each_line("\n") do |line|
            number += 1
            line = line.force_encoding(Encoding::UTF_8)
            line = line.scrub unless line.valid_encoding?
            found = pattern.match(line)
            yield number, excerpt(line, found) if found
          end
        end
      rescue SystemCallError, IOError
        nil
      end

      def excerpt(line, found)
        room = (EXCERPT_BYTES - found[0].bytesize) / 2
        from = [found.begin(0) - [room, 0].max, 0].max
        slice = line[from, EXCERPT_BYTES].to_s.chomp
        slice = slice.byteslice(0, EXCERPT_BYTES).to_s.scrub("")
        "#{from.positive? ? '...' : ''}#{slice}"
      end

      def relative(root, path)
        path.delete_prefix("#{Record::Scope.dir(root)}/")
      end
    end
  end
end
