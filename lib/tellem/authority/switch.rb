# frozen_string_literal: true

require_relative "../ports/harness_paths"
require_relative "../record/fs"

module Tellem
  module Authority
    module Switch
      ENV_KEY = "TELLEM_AUTHORITY_DISABLED"
      FLAG = "authority.off"
      ON = "1"
      OFF = "0"
      READ_FLAGS = File::RDONLY | File::NOFOLLOW

      module_function

      def flag_path
        File.join(Ports::HarnessPaths.state_dir, FLAG)
      end

      def reason
        value = ENV[ENV_KEY]
        return "environment" if value == ON
        return nil if value == OFF

        flag
      end

      def off?
        !reason.nil?
      end

      def flag
        File.open(flag_path, READ_FLAGS) { |file| file.read(1) }
        "flag_file"
      rescue Errno::ENOENT, Errno::ENOTDIR
        nil
      rescue SystemCallError, IOError
        "flag_unreadable"
      end

      def set(text)
        Record::FS.mkdir_p(Ports::HarnessPaths.state_dir)
        Record::FS.replace(flag_path, "#{text}\n")
        flag_path
      end

      def clear
        File.unlink(flag_path)
        true
      rescue Errno::ENOENT, Errno::ENOTDIR
        false
      end
    end
  end
end
