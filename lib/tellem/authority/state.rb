# frozen_string_literal: true

require "json"
require_relative "../config/resolver"
require_relative "../errors"
require_relative "../ports/harness_paths"
require_relative "../record/fs"
require_relative "../record/reader"
require_relative "switch"

module Tellem
  module Authority
    module State
      SCHEMA = "tellem.authority/v1"
      OBSERVE = "observe"
      SPOOL = "spool"
      REHEARSE = "rehearse"
      OWN = "own"
      WITH_ENV = [REHEARSE, OWN].freeze
      HARNESSES = %w[claude codex].freeze
      NS = 1_000_000_000

      module_function

      def dir
        File.join(Ports::HarnessPaths.state_dir, "authority")
      end

      def file
        File.join(dir, "state.json")
      end

      def receipts_file
        File.join(dir, "receipts.jsonl")
      end

      def backup_dir(stamp)
        File.join(dir, "backup", stamp)
      end

      def read
        data = JSON.parse(Record::FS.read(file))
        data.is_a?(Hash) ? data : {}
      rescue Errno::ENOENT, Errno::ENOTDIR, JSON::ParserError
        {}
      end

      def write(data)
        Record::FS.mkdir_p(dir)
        Record::FS.replace(file, "#{JSON.pretty_generate(data)}\n")
      end

      def harness(name)
        read.dig("harnesses", name)
      end

      def level(name)
        value = Config.get("authority.#{name}")
        value.is_a?(String) ? value : OBSERVE
      rescue UsageError
        OBSERVE
      end

      def generation
        read["generation"].to_i
      end

      def losses
        Array(read["lost"])
      end

      def applied_ns(name)
        value = harness(name)&.fetch("applied_ns", nil)
        value.is_a?(Integer) ? value : nil
      end

      def applied(plan_id, name, level:, prior:, env: {}, settings_path: nil)
        data = read
        data["schema"] = SCHEMA
        data["harnesses"] ||= {}
        data["harnesses"][name] = {
          "plan_id" => plan_id, "level" => level, "prior" => prior, "applied_at" => Record::FS.rfc3339, "applied_ns" => Record::FS.now_ns,
          "env" => env, "settings_path" => settings_path
        }
        data["lost"] = Array(data["lost"]).reject { |item| item["harness"] == name } if level == OWN
        write(data)
      end

      def rolled_back(plan_id)
        data = read
        harnesses = data["harnesses"] || {}
        names = harnesses.select { |_name, entry| entry["plan_id"] == plan_id }.keys
        names.each { |name| harnesses.delete(name) }
        data["harnesses"] = harnesses
        data["lost"] = Array(data["lost"]).reject { |item| item["plan_id"] == plan_id }
        write(data)
      end

      def lowered(name, kind:, reason:, session_key:, from:, to:, restored: nil)
        data = read
        data["schema"] = SCHEMA
        data["generation"] = data["generation"].to_i + 1 if kind != "stop_switch"
        entry = (data["harnesses"] ||= {})[name] ||= {}
        entry["level"] = to
        entry["restored_from"] = from
        entry["restored"] = (entry["restored"] || {}).merge(restored) if restored
        entry.delete("restore_failed")
        unless kind == "stop_switch"
          (data["lost"] ||= []) << { "harness" => name, "kind" => kind, "reason" => reason, "session_key" => session_key, "at" => Record::FS.rfc3339,
                                     "from" => from, "plan_id" => entry["plan_id"] }
        end
        write(data)
      end

      def restore_failure(name)
        found = harness(name)&.fetch("restore_failed", nil)
        found.is_a?(Hash) ? found : nil
      end

      def restore_failures
        (read["harnesses"] || {}).each_with_object({}) do |(name, entry), found|
          found[name] = entry["restore_failed"] if entry.is_a?(Hash) && entry["restore_failed"].is_a?(Hash)
        end
      end

      def restore_failed?(name)
        !restore_failure(name).nil?
      end

      def restore_failed(name, failure)
        data = read
        data["schema"] = SCHEMA
        entry = (data["harnesses"] ||= {})[name] ||= {}
        prior = entry["restore_failed"].is_a?(Hash) ? entry["restore_failed"] : {}
        now = Record::FS.rfc3339
        entry["restore_failed"] = failure.merge("first_at" => prior["first_at"] || now, "at" => now, "attempts" => prior["attempts"].to_i + 1)
        write(data)
        entry["restore_failed"]
      end

      def restore_cleared(name)
        data = read
        entry = data.dig("harnesses", name)
        return unless entry.is_a?(Hash) && entry.key?("restore_failed")

        entry.delete("restore_failed")
        write(data)
      end

      def restored_sha(plan_id, path)
        (read["harnesses"] || {}).each_value do |entry|
          next unless entry["plan_id"] == plan_id

          found = entry.dig("restored", path)
          return found if found
        end
        nil
      end

      def spool_owed?(name)
        level(name) == REHEARSE || harness(name)&.fetch("restored_from", nil) == REHEARSE
      end

      def receipt(record)
        Record::FS.mkdir_p(dir)
        line = JSON.generate({ "schema" => SCHEMA, "at" => Record::FS.rfc3339 }.merge(record))
        file = Record::FS.open_append(receipts_file)
        begin
          file.flock(File::LOCK_EX)
          Record::FS.write_all(file, "#{line}\n")
          file.fsync
        ensure
          file.close
        end
        record
      end

      def receipts
        return [] unless Record::FS.lexists?(receipts_file)

        Record::Reader.records(receipts_file).first
      end
    end
  end
end
