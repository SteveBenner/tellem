# frozen_string_literal: true

require_relative "../errors"
require_relative "schemas"

module Tellem
  module Record
    module FS
      SCOPE_MARK = "/#{Schemas::SCOPE_DIR}".freeze
      WRITE_FLAGS = File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW
      APPEND_FLAGS = File::RDWR | File::APPEND | File::CREAT | File::NOFOLLOW
      READ_FLAGS = File::RDONLY | File::NOFOLLOW

      module_function

      def mkdir_p(path, mode = Schemas::DIR_MODE)
        guard = guarded_prefix(path)
        missing = []
        current = path
        until lexists?(current)
          missing.unshift(current)
          parent = File.dirname(current)
          break if parent == current

          current = parent
        end
        refuse_symlinks(path, guard) if guard
        missing.each do |dir|
          Dir.mkdir(dir, mode)
        rescue Errno::EEXIST
          nil
        end
        refuse_symlinks(path, guard) if guard
        path
      end

      def guarded_prefix(path)
        index = path.index("#{SCOPE_MARK}/") || (path.end_with?(SCOPE_MARK) ? path.length - SCOPE_MARK.length : nil)
        index && path[0, index + SCOPE_MARK.length]
      end

      def refuse_symlinks(path, guard)
        current = guard
        rest = path[guard.length..].to_s.split("/").reject(&:empty?)
        [nil, *rest].each do |part|
          current = File.join(current, part) if part
          stat = lstat(current)
          break unless stat
          raise SymlinkRefused.new("symlinked record path refused", detail: { "path" => current }) if stat.symlink?
        end
      end

      def lstat(path)
        File.lstat(path)
      rescue Errno::ENOENT, Errno::ENOTDIR
        nil
      end

      def lexists?(path)
        !lstat(path).nil?
      end

      def open_append(path)
        File.open(path, APPEND_FLAGS, Schemas::FILE_MODE)
      rescue Errno::ELOOP
        raise SymlinkRefused.new("symlinked record file refused", detail: { "path" => path }), cause: nil
      end

      def open_read(path, &block)
        File.open(path, READ_FLAGS, &block)
      rescue Errno::ELOOP
        raise SymlinkRefused.new("symlinked record file refused", detail: { "path" => path }), cause: nil
      end

      def read(path)
        open_read(path) { |file| file.read }
      end

      def write_all(file, data)
        offset = 0
        offset += file.syswrite(data.byteslice(offset..)) while offset < data.bytesize
        offset
      end

      def write_new(path, bytes)
        tmp = temp_path(path)
        File.open(tmp, WRITE_FLAGS, Schemas::FILE_MODE) do |file|
          write_all(file, bytes)
          file.fsync
        end
        begin
          File.link(tmp, path)
          created = true
        rescue Errno::EEXIST
          created = false
        ensure
          unlink_quiet(tmp)
        end
        fsync_dir(File.dirname(path))
        created
      end

      def replace(path, bytes)
        tmp = temp_path(path)
        File.open(tmp, WRITE_FLAGS, Schemas::FILE_MODE) do |file|
          write_all(file, bytes)
          file.fsync
        end
        refuse_target_symlink(path)
        File.rename(tmp, path)
        fsync_dir(File.dirname(path))
        path
      rescue StandardError
        unlink_quiet(tmp) if tmp
        raise
      end

      def refuse_target_symlink(path)
        stat = lstat(path)
        raise SymlinkRefused.new("symlinked record file refused", detail: { "path" => path }) if stat&.symlink?
      end

      def temp_path(path)
        "#{path}.#{Process.pid}.#{Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)}.tmp"
      end

      def unlink_quiet(path)
        File.unlink(path)
      rescue SystemCallError
        nil
      end

      def fsync_file(path)
        File.open(path, READ_FLAGS) { |handle| handle.fsync }
        true
      rescue Errno::ENOENT
        false
      rescue Errno::ELOOP
        raise SymlinkRefused.new("symlinked record file refused", detail: { "path" => path }), cause: nil
      end

      def flush(path, new_file: false)
        flushed = fsync_file(path)
        fsync_dir(File.dirname(path)) if flushed && new_file
        flushed
      end

      def fsync_dir(dir)
        File.open(dir, File::RDONLY) { |handle| handle.fsync }
      rescue SystemCallError
        nil
      end

      def now_ns
        Process.clock_gettime(Process::CLOCK_REALTIME, :nanosecond)
      end

      def rfc3339_ms(ns = now_ns)
        Time.at(ns / 1_000_000_000, ns % 1_000_000_000, :nsec).utc.strftime("%Y-%m-%dT%H:%M:%S.%LZ")
      end

      def rfc3339(time = Time.now)
        time.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
      end

      def host
        @host ||= begin
          name = File.read("/proc/sys/kernel/hostname").strip
          name.empty? ? socket_host : name
        rescue SystemCallError
          socket_host
        end
      end

      def socket_host
        require "socket"
        Socket.gethostname
      end
    end
  end
end
