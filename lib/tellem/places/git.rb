# frozen_string_literal: true

require_relative "../bounds"

module Tellem
  module Places
    module Git
      DEFAULT_TIMEOUT_MS = 2000
      OUTPUT_BYTES = Bounds::RECORD_BYTES
      READ_CHUNK = 65_536
      POLL_SECONDS = 0.001
      ENV = {
        "GIT_OPTIONAL_LOCKS" => "0",
        "GIT_TERMINAL_PROMPT" => "0",
        "GIT_PAGER" => "cat",
        "PAGER" => "cat",
        "LC_ALL" => "C",
        "GIT_DIR" => nil,
        "GIT_WORK_TREE" => nil,
        "GIT_INDEX_FILE" => nil,
        "GIT_COMMON_DIR" => nil,
        "GIT_OBJECT_DIRECTORY" => nil,
        "GIT_NAMESPACE" => nil,
        "GIT_PREFIX" => nil,
        "GIT_TRACE" => nil,
        "GIT_TRACE2" => nil,
        "GIT_TRACE2_EVENT" => nil,
        "GIT_TRACE2_PERF" => nil
      }.freeze
      CONFIG = ["-c", "core.fsmonitor=false", "-c", "gc.auto=0", "-c", "maintenance.auto=false"].freeze

      Result = Struct.new(:status, :stdout, :exit_code, :duration_ms, :cause, keyword_init: true) do
        def ok?
          status == :ok
        end

        def lines
          stdout.to_s.split("\n")
        end
      end

      module_function

      def now_ms
        Process.clock_gettime(Process::CLOCK_MONOTONIC, :millisecond)
      end

      def deadline(timeout_ms)
        now_ms + bound(timeout_ms)
      end

      def bound(timeout_ms)
        value = Integer(timeout_ms)
        value.positive? ? value : DEFAULT_TIMEOUT_MS
      rescue ArgumentError, TypeError
        DEFAULT_TIMEOUT_MS
      end

      def run(args, chdir:, timeout_ms: DEFAULT_TIMEOUT_MS, until_ms: nil)
        started = now_ms
        stop_at = until_ms || (started + bound(timeout_ms))
        return finish(:failed, started, cause: "directory_missing") unless chdir && File.directory?(chdir)
        return finish(:timeout, started, cause: "timeout") if now_ms >= stop_at

        execute(args, chdir, started, stop_at)
      end

      def execute(args, chdir, started, stop_at)
        reader, writer = IO.pipe
        begin
          pid = Process.spawn(ENV, "git", "--no-optional-locks", *CONFIG, *args,
                              chdir: chdir, pgroup: true, in: File::NULL, out: writer, err: File::NULL)
        rescue SystemCallError
          return finish(:unavailable, started, cause: "git_unavailable")
        ensure
          writer.close
        end
        supervise(pid, reader, started, stop_at)
      ensure
        reader&.close unless reader&.closed?
      end

      def supervise(pid, reader, started, stop_at)
        output = +""
        eof = drain(reader, output, stop_at)
        status = eof ? await_exit(pid, stop_at) : nil
        unless status
          sweep(pid)
          Process.wait(pid)
          pid = nil
          return finish(:timeout, started, cause: "timeout")
        end
        pid = nil
        return finish(:ok, started, stdout: output, exit_code: 0) if status.success?

        finish(:failed, started, stdout: output, exit_code: status.exitstatus, cause: "git_failed")
      ensure
        if pid
          sweep(pid)
          reap(pid)
        end
      end

      def drain(reader, output, stop_at)
        loop do
          remaining = stop_at - now_ms
          return false if remaining <= 0
          return false unless reader.wait_readable(remaining / 1000.0)

          chunk = reader.read_nonblock(READ_CHUNK, exception: false)
          next if chunk == :wait_readable
          return true if chunk.nil?

          room = OUTPUT_BYTES - output.bytesize
          output << chunk.byteslice(0, room) if room.positive?
        end
      end

      def await_exit(pid, stop_at)
        loop do
          if zombie?(pid)
            sweep(pid)
            return Process.wait2(pid).last
          end
          unless proc_visible?(pid)
            reaped = Process.wait2(pid, Process::WNOHANG)
            return reaped.last if reaped
          end
          return nil if now_ms >= stop_at

          sleep POLL_SECONDS
        end
      end

      def zombie?(pid)
        stat = File.read("/proc/#{pid}/stat")
        stat[stat.rindex(")") + 2] == "Z"
      rescue SystemCallError, NoMethodError
        false
      end

      def proc_visible?(pid)
        File.exist?("/proc/#{pid}/stat")
      end

      def sweep(pid)
        Process.kill(:KILL, -pid)
      rescue Errno::ESRCH, Errno::EPERM
        nil
      end

      def reap(pid)
        Process.wait(pid)
      rescue Errno::ECHILD
        nil
      end

      def finish(status, started, stdout: nil, exit_code: nil, cause: nil)
        Result.new(status: status, stdout: stdout, exit_code: exit_code, duration_ms: now_ms - started, cause: cause)
      end
    end
  end
end
