# frozen_string_literal: true

require "json"
require_relative "../ports/harness_paths"

module Tellem
  module Otel
    module Settings
      KILL_SWITCH = "TELLEM_OTEL_DISABLED"
      RECEIVER_KEY = "otel.receiver"
      PORT_KEY = "otel.port"
      DEFAULT_PORT = 43_180
      SECRET = "otel_token"
      HOST = "127.0.0.1"
      INHERIT_FLAG = "--inherited"
      LISTEN_FD = 3
      LOCK_FD = 4
      SPOOL_ENTRY = "otel/spool"
      TRUE_WORDS = %w[1 true on yes].freeze
      FALSE_WORDS = %w[0 false off no].freeze

      module_function

      def disabled?
        ENV[KILL_SWITCH] == "1"
      end

      def enabled?
        return false if disabled?

        value = configured(RECEIVER_KEY)
        value.nil? ? false : value == true
      end

      def port
        value = configured(PORT_KEY)
        value.is_a?(Integer) && value.between?(1, 65_535) ? value : DEFAULT_PORT
      end

      def configured(key)
        return file_value(key) unless defined?(Tellem::Config) && defined?(Rplugin::Settings)

        Tellem::Config.get(key)
      rescue Tellem::UsageError
        file_value(key)
      end

      def file_value(key)
        forced = env_value(key)
        forced.nil? ? snapshot_value(key) : forced
      end

      def env_value(key)
        text = ENV.fetch("RPLUGIN_#{Ports::HarnessPaths::PLUGIN_ID}_#{key}".upcase.gsub(/[^A-Z0-9]+/, "_"), nil)
        return nil if text.nil?

        word = text.strip.downcase
        return true if TRUE_WORDS.include?(word)
        return false if FALSE_WORDS.include?(word)

        Integer(word, 10)
      rescue ArgumentError
        nil
      end

      def snapshot_value(key)
        path = File.join(Ports::HarnessPaths.rplugin_paths.state_home, Ports::HarnessPaths::PLUGIN_ID, "settings.resolved.json")
        data = JSON.parse(File.read(path))
        machine = data.is_a?(Hash) ? data["machine"] : nil
        machine.is_a?(Hash) ? machine[key] : nil
      rescue Errno::ENOENT, Errno::ENOTDIR, Errno::EACCES, JSON::ParserError
        nil
      end

      def dir
        File.join(Ports::HarnessPaths.state_dir, "otel")
      end

      def pid_file
        File.join(dir, "receiver.pid")
      end

      def lock_file
        File.join(dir, "receiver.lock")
      end

      def status_file
        File.join(dir, "receiver.json")
      end

      def spool(session_key)
        File.join(dir, "#{session_key}.jsonl")
      end
    end
  end
end
