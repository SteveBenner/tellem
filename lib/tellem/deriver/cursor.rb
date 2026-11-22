# frozen_string_literal: true

require "json"
require_relative "../ids"
require_relative "../record/fs"
require_relative "../record/scope"
require_relative "../record/writer"

module Tellem
  module Deriver
    class Cursor
      def self.load(root)
        data = JSON.parse(Record::FS.read(Record::Scope.cursor_file(root)))
        new(root, data.is_a?(Hash) && data["sessions"].is_a?(Hash) ? data["sessions"] : {})
      rescue Errno::ENOENT, JSON::ParserError
        new(root, {})
      end

      def initialize(root, sessions)
        @root = root
        @sessions = sessions
        @updates = {}
        @flushes = {}
      end

      def session(key)
        entry = @sessions[key]
        entry.is_a?(Hash) ? entry : {}
      end

      def raw(key, agent_key)
        value = session(key).dig("raw", agent_key)
        value.is_a?(Hash) ? value : nil
      end

      def natives(key)
        value = session(key)["native"]
        value.is_a?(Hash) ? value : {}
      end

      def rendered(key, agent_key)
        session(key).dig("rendered", agent_key)
      end

      def update(key, entry, raw_paths)
        @updates[key] = entry
        raw_paths.each do |agent_key, path|
          @flushes[path] = raw(key, agent_key).nil?
        end
      end

      def save
        return false if @updates.empty?

        @flushes.sort.each { |path, new_file| Record::FS.flush(path, new_file: new_file) }
        merged = @sessions.merge(@updates)
        document = { "sessions" => sorted(merged) }
        Record::Writer.replace_if_changed(Record::Scope.cursor_file(@root), "#{JSON.generate(document)}\n")
      end

      def sorted(value)
        case value
        when Hash then value.keys.sort.to_h { |key| [key, sorted(value[key])] }
        when Array then value.map { |item| sorted(item) }
        else value
        end
      end

      def self.stat(path)
        stat = File.lstat(path)
        return nil unless stat.file?

        { "path" => path, "inode" => stat.ino, "size" => stat.size, "mtime_ns" => (stat.mtime.to_r * 1_000_000_000).to_i }
      rescue SystemCallError
        nil
      end
    end
  end
end
