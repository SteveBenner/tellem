# frozen_string_literal: true

require "digest"
require "open3"
require_relative "../errors"
require_relative "../record/fs"
require_relative "../record/schemas"

module Tellem
  module Cutover
    module Files
      CREATE_FLAGS = File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW
      DIFF_TIMEOUT_S = 30

      module_function

      def sha256(bytes)
        bytes.nil? ? nil : Digest::SHA256.hexdigest(bytes)
      end

      def current(path)
        stat = Record::FS.lstat(path)
        return [nil, nil] unless stat
        raise SymlinkRefused.new("planned file is a symlink", detail: { "path" => path }) if stat.symlink?
        raise OperationalFailure.new("planned path is not a regular file", detail: { "path" => path }) unless stat.file?

        [Record::FS.read(path).b, stat.mode & 0o7777]
      end

      def write(path, bytes, mode)
        Record::FS.refuse_target_symlink(path)
        tmp = Record::FS.temp_path(path)
        File.open(tmp, CREATE_FLAGS, Record::Schemas::FILE_MODE) do |file|
          Record::FS.write_all(file, bytes)
          file.fsync
        end
        File.chmod(mode, tmp)
        File.rename(tmp, path)
        Record::FS.fsync_dir(File.dirname(path))
        path
      rescue StandardError
        Record::FS.unlink_quiet(tmp) if tmp
        raise
      end

      def remove(path)
        Record::FS.refuse_target_symlink(path)
        File.unlink(path)
        Record::FS.fsync_dir(File.dirname(path))
      end

      def backup(dir, index, path, bytes, mode)
        Record::FS.mkdir_p(dir)
        name = format("%<index>03d-%<name>s", index: index, name: File.basename(path))
        target = File.join(dir, name)
        Record::FS.replace(target, bytes)
        { "path" => path, "backup" => name, "sha256" => sha256(bytes), "mode" => mode }
      end

      def diff(work_dir, label, before, after)
        return "" if before == after

        Record::FS.mkdir_p(work_dir)
        old = File.join(work_dir, "diff.old.tmp")
        new = File.join(work_dir, "diff.new.tmp")
        [[old, before], [new, after]].each do |path, bytes|
          Record::FS.unlink_quiet(path)
          File.open(path, CREATE_FLAGS, Record::Schemas::FILE_MODE) { |file| Record::FS.write_all(file, bytes.to_s) }
        end
        labels = ["--label", before.nil? ? "/dev/null" : "a/#{label}", "--label", after.nil? ? "/dev/null" : "b/#{label}"]
        run_diff(["diff", "-u", *labels, old, new])
      ensure
        [old, new].each { |path| Record::FS.unlink_quiet(path) if path }
      end

      def run_diff(argv)
        output = +""
        Open3.popen2(*argv, err: File::NULL, pgroup: true) do |stdin, stdout, wait|
          stdin.close
          reader = Thread.new { stdout.read.to_s }
          unless wait.join(DIFF_TIMEOUT_S)
            Process.kill("KILL", -wait.pid)
            raise OperationalFailure.new("diff did not finish within #{DIFF_TIMEOUT_S} s", next_command: "tellem cutover plan")
          end
          output = reader.value
          raise OperationalFailure.new("diff failed with status #{wait.value.exitstatus}") if wait.value.exitstatus.to_i > 1
        end
        output.b
      rescue Errno::ENOENT
        raise CapabilityUnavailable.new("the diff command is not installed", next_command: "install diffutils")
      end
    end
  end
end
