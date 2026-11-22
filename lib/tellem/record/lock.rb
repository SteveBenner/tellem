# frozen_string_literal: true

require_relative "fs"
require_relative "scope"

module Tellem
  module Record
    module Lock
      POLL_S = 0.05
      LOCK_FLAGS = File::RDWR | File::CREAT | File::NOFOLLOW

      module_function

      def acquire(scope_root)
        Scope.prepare(scope_root)
        file = open_lock(scope_root)
        return file if file.flock(File::LOCK_EX | File::LOCK_NB)

        file.close
        mark_dirty(scope_root)
        nil
      end

      def release(handle)
        return unless handle

        handle.flock(File::LOCK_UN)
        handle.close
      end

      def with_lock(scope_root)
        handle = acquire(scope_root)
        return :busy unless handle

        begin
          yield
        ensure
          release(handle)
        end
      end

      def held?(scope_root)
        return false unless FS.lexists?(Scope.lock_file(scope_root))

        file = open_lock(scope_root)
        begin
          return true unless file.flock(File::LOCK_EX | File::LOCK_NB)

          file.flock(File::LOCK_UN)
          false
        ensure
          file.close
        end
      end

      def wait_idle(scope_root, timeout_s:)
        deadline = monotonic + timeout_s
        loop do
          return true unless held?(scope_root)
          return false if monotonic >= deadline

          sleep POLL_S
        end
      end

      def mark_dirty(scope_root)
        path = Scope.dirty_file(scope_root)
        FS.refuse_target_symlink(path)
        File.open(path, File::WRONLY | File::CREAT | File::NOFOLLOW, Schemas::FILE_MODE) { |file| file.write("") }
        true
      end

      def dirty?(scope_root)
        FS.lexists?(Scope.dirty_file(scope_root))
      end

      def clear_dirty(scope_root)
        FS.unlink_quiet(Scope.dirty_file(scope_root))
        nil
      end

      def open_lock(scope_root)
        File.open(Scope.lock_file(scope_root), LOCK_FLAGS, Schemas::FILE_MODE)
      rescue Errno::ELOOP
        raise SymlinkRefused.new("symlinked derive lock refused"), cause: nil
      end

      def monotonic
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
