# frozen_string_literal: true

require "digest"
require_relative "../errors"
require_relative "../record/fs"
require_relative "../record/schemas"

module Tellem
  module Specstory
    module Anchor
      OPEN_FLAGS = File::RDONLY | File::NOFOLLOW
      NS = 1_000_000_000
      CHUNK = 1 << 20

      module_function

      def open_directory(path)
        io = File.open(path, OPEN_FLAGS)
        return io if io.stat.directory?

        io.close
        raise SymlinkRefused.new("not a plain directory, refused", detail: { "path" => path })
      rescue Errno::ELOOP, Errno::ENOTDIR
        raise SymlinkRefused.new("not a plain directory, refused", detail: { "path" => path }), cause: nil
      end

      def fd_path(io)
        "/proc/self/fd/#{io.fileno}"
      end

      def named?(link, targets)
        real = real_path(link)
        return nil unless real

        targets.any? { |target| real_path(target) == real } ? real : nil
      end

      def real_path(path)
        File.realpath(path)
      rescue SystemCallError
        nil
      end

      def mtime_ns(stat)
        (stat.mtime.to_r * NS).to_i
      end

      def digest(path)
        sha = Digest::SHA256.new
        bytes = 0
        Record::FS.open_read(path) do |file|
          while (chunk = file.read(CHUNK))
            sha.update(chunk)
            bytes += chunk.bytesize
          end
        end
        { "bytes" => bytes, "sha256" => sha.hexdigest }
      end

      def anchored(base)
        io = open_directory(base)
        before = Record::FS.lstat(base)
        raise SymlinkRefused.new("directory changed while opening", detail: { "path" => base }) unless before && !before.symlink? && before.ino == io.stat.ino && before.dev == io.stat.dev

        yield fd_path(io)
      ensure
        io&.close
      end

      def clean_chain?(fd, rel)
        current = fd
        rel.split("/")[0...-1].all? do |part|
          current = File.join(current, part)
          stat = Record::FS.lstat(current)
          stat&.directory? && !stat.symlink?
        end
      end

      def unlink(fd, item, deep: false)
        return :changed unless clean_chain?(fd, item["rel"])

        path = File.join(fd, item["rel"])
        stat = Record::FS.lstat(path)
        return :absent unless stat
        return :changed if stat.symlink? || !stat.file?
        return :changed unless stat.ino == item["inode"] && stat.size == item["size"] && mtime_ns(stat) == item["mtime_ns"]
        return :changed if deep && digest(path) != item.slice("bytes", "sha256")

        File.unlink(path)
        :removed
      rescue Errno::ENOENT
        :absent
      rescue SystemCallError
        :changed
      end

      def rmdir(fd, item)
        return :changed unless clean_chain?(fd, item["rel"])

        path = File.join(fd, item["rel"])
        stat = Record::FS.lstat(path)
        return :absent unless stat
        return :changed if stat.symlink? || !stat.directory?

        Dir.rmdir(path)
        Record::FS.fsync_dir(File.dirname(path))
        :removed
      rescue Errno::ENOENT
        :absent
      rescue SystemCallError
        :changed
      end
    end
  end
end
