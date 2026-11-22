# frozen_string_literal: true

require "json"
require_relative "../record/fs"
require_relative "../record/schemas"
require_relative "settings"

module Tellem
  module Otel
    module State
      COUNTERS = %w[requests events_kept events_ignored].freeze
      ERROR_KEYS = %w[error_class errno error].freeze

      module_function

      def read
        data = JSON.parse(Record::FS.read(Settings.status_file))
        data.is_a?(Hash) ? data : {}
      rescue SystemCallError, Tellem::Error, JSON::ParserError, EncodingError
        {}
      end

      def write(data)
        Record::FS.mkdir_p(Settings.dir)
        path = Settings.status_file
        tmp = Record::FS.temp_path(path)
        File.open(tmp, Record::FS::WRITE_FLAGS, Record::Schemas::FILE_MODE) { |file| Record::FS.write_all(file, "#{JSON.generate(data)}\n") }
        Record::FS.refuse_target_symlink(path)
        File.rename(tmp, path)
        data
      rescue SystemCallError, Tellem::Error, JSON::GeneratorError
        Record::FS.unlink_quiet(tmp) if tmp
        nil
      end

      def merge(changes)
        write(read.merge(changes))
      end

      def now
        Time.now.utc.strftime("%Y-%m-%dT%H:%M:%S.%LZ")
      end

      def pid
        text = Record::FS.read(Settings.pid_file)
        value = Integer(text.strip, 10)
        value.positive? ? value : nil
      rescue Errno::ENOENT, Errno::ENOTDIR, ArgumentError, Tellem::SymlinkRefused
        nil
      end

      def alive?(pid)
        return false unless pid

        Process.kill(0, pid)
        cmdline = File.binread("/proc/#{pid}/cmdline")
        cmdline.include?("tellem-otel")
      rescue Errno::ENOENT
        true
      rescue SystemCallError
        false
      end

      def running_pid
        current = pid
        alive?(current) ? current : nil
      end
    end
  end
end
