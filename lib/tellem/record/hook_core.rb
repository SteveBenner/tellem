# frozen_string_literal: true

require "json"
require_relative "../errors"
require_relative "../ids"
require_relative "../ports/harness_paths"
require_relative "exclude"
require_relative "fs"
require_relative "schemas"
require_relative "scope"

module Tellem
  module Record
    module HookCore
      RAW_LINE_BYTES = 65_536
      NEWLINE = "\n"
      GAP_KEYS = %w[harness harness_event event session_key error_class errno payload_bytes over_limit missing_keys tellem_version].freeze
      GAP_STRING_BYTES = 200

      module_function

      def append(path, line, sync: sync_requested?)
        raise InvalidRecord.new("record line contains a newline") if line.include?(NEWLINE)
        raise InputTooLarge.new("raw_line_bytes bound exceeded", detail: { "bytes" => line.bytesize + 1 }) if line.bytesize + 1 > RAW_LINE_BYTES

        FS.mkdir_p(File.dirname(path))
        file = FS.open_append(path)
        begin
          file.flock(File::LOCK_EX)
          size = file.size
          sealed = size.positive? && file.pread(1, size - 1) != NEWLINE
          data = sealed ? "#{NEWLINE}#{line}#{NEWLINE}" : "#{line}#{NEWLINE}"
          FS.write_all(file, data)
          file.flock(File::LOCK_UN)
          if sync
            file.fsync
            FS.fsync_dir(File.dirname(path)) if size.zero?
          end
          { "bytes" => data.bytesize, "sealed" => sealed, "offset" => size }
        ensure
          file.close
        end
      end

      def home_for(session_key, cwd, inferred: false)
        raise InvalidRecord.new("invalid session key") unless Ids.valid_session_key?(session_key)

        path = File.join(Ports::HarnessPaths.homes_dir, session_key)
        entry = read_home(path)
        if excluded_home?(entry)
          entry = home_entry(Scope.user_root, entry["inferred"])
          FS.replace(path, "#{JSON.generate(entry)}#{NEWLINE}")
        end
        unless entry
          entry = new_home(cwd, inferred)
          FS.mkdir_p(File.dirname(path))
          entry = read_home(path) || entry unless FS.write_new(path, "#{JSON.generate(entry)}#{NEWLINE}")
        end
        Scope.prepare(entry["root"])
        entry
      end

      def excluded_home?(entry)
        entry.is_a?(Hash) && entry["root"] != Scope.user_root && Exclude.covers?(entry["root"])
      end

      def new_home(cwd, inferred)
        home_entry(Scope.locate(cwd), inferred)
      end

      def home_entry(root, inferred)
        {
          "schema" => Schemas::HOME,
          "root" => root,
          "scope_id" => Ids.scope_id(FS.host, root),
          "kind" => Scope.kind(root),
          "inferred" => inferred ? true : false
        }
      end

      def read_home(path)
        data = JSON.parse(FS.read(path))
        data.is_a?(Hash) && data["schema"] == Schemas::HOME && data["root"].is_a?(String) ? data : nil
      rescue Errno::ENOENT
        nil
      rescue JSON::ParserError
        nil
      end

      def raw_path(entry, session_key, agent_key)
        Scope.raw_path(entry["root"], session_key, agent_key)
      end

      def sync_requested?
        FS.lexists?(Ports::HarnessPaths.capture_fsync_flag)
      end

      def capture_enabled?(scope_root = nil)
        return false if ENV["TELLEM_DISABLED"] == "1"
        return false unless FS.lexists?(Ports::HarnessPaths.capture_flag)
        return false if scope_root && FS.lexists?(Scope.capture_off(scope_root))

        true
      end

      def hook_gap(cause, fields = {})
        record = { "ts" => FS.rfc3339_ms, "cause" => cause.to_s[0, GAP_STRING_BYTES] }
        fields.each do |key, value|
          name = key.to_s
          next unless GAP_KEYS.include?(name)

          clean = gap_value(value)
          record[name] = clean unless clean.nil?
        end
        FS.mkdir_p(Ports::HarnessPaths.state_dir)
        append(Ports::HarnessPaths.hook_gaps, JSON.generate(record))
      end

      def gap_value(value)
        case value
        when String then value[0, GAP_STRING_BYTES]
        when Integer, true, false then value
        when Array then value.grep(String).map { |item| item[0, GAP_STRING_BYTES] }.first(64)
        end
      end
    end
  end
end
