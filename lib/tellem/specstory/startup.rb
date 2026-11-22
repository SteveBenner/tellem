# frozen_string_literal: true

require_relative "../discovery"
require_relative "../record/fs"
require_relative "anchor"

module Tellem
  module Specstory
    module Startup
      module_function

      def blocks(real, name, shape)
        text = File.binread(real).force_encoding(Encoding::UTF_8)
        lines = text.lines
        found = Discovery::Incumbent.blocks(lines, real.end_with?(".fish")).select do |block|
          block[:name] == name && block[:shape] == shape && lines[(block[:from] - 1)..(block[:to] - 1)].join.match?(/\b#{Discovery::Incumbent::TOOL}\b/)
        end
        [lines, found]
      end

      def present?(file, name, shape)
        real = Anchor.real_path(file)
        return false unless real

        blocks(real, name, shape).last.any?
      rescue SystemCallError
        false
      end

      def remove(file, name, shape)
        real = Anchor.real_path(file)
        return :absent unless real

        before = Record::FS.lstat(real)
        return :changed unless before&.file?

        lines, found = blocks(real, name, shape)
        return :absent if found.empty?

        drop = found.flat_map { |block| ((block[:from] - 1)..(block[:to] - 1)).to_a }
        kept = lines.each_with_index.reject { |_line, index| drop.include?(index) }.map(&:first).join
        replace(real, kept, before)
      end

      def replace(real, bytes, before)
        tmp = Record::FS.temp_path(real)
        File.open(tmp, Record::FS::WRITE_FLAGS, before.mode & 0o7777) do |file|
          Record::FS.write_all(file, bytes)
          file.fsync
        end
        File.chmod(before.mode & 0o7777, tmp)
        fresh = Record::FS.lstat(real)
        unless fresh&.file? && fresh.ino == before.ino && fresh.size == before.size && Anchor.mtime_ns(fresh) == Anchor.mtime_ns(before)
          Record::FS.unlink_quiet(tmp)
          return :changed
        end
        File.rename(tmp, real)
        Record::FS.fsync_dir(File.dirname(real))
        :removed
      rescue SystemCallError
        Record::FS.unlink_quiet(tmp) if tmp
        :changed
      end
    end
  end
end
