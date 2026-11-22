# frozen_string_literal: true

require "json"
require_relative "../cutover/apply"
require_relative "../ports/harness_paths"
require_relative "../record/fs"
require_relative "../record/schemas"
require_relative "../record/reader"
require_relative "../retention/remove"

module Tellem
  module Specstory
    module State
      SCHEMA = "tellem.specstory-removal/v1"
      STATE_SCHEMA = "tellem.specstory-removal-state/v1"
      DIR = "specstory"
      STATE_FILE = "removal.json"
      LOG = "removal.jsonl"
      LOCK = "removal.lock"
      DRIFT_FILE = "drift.json"
      LOCK_FLAGS = File::RDWR | File::CREAT | File::NOFOLLOW

      module_function

      def dir
        File.join(Ports::HarnessPaths.state_dir, DIR)
      end

      def state_file
        File.join(dir, STATE_FILE)
      end

      def log_file
        File.join(dir, LOG)
      end

      def drift_file
        File.join(dir, DRIFT_FILE)
      end

      def read
        data = JSON.parse(Record::FS.read(state_file))
        data.is_a?(Hash) ? data : nil
      rescue Errno::ENOENT, Errno::ENOTDIR, JSON::ParserError
        nil
      end

      def write(data)
        Record::FS.mkdir_p(dir)
        Record::FS.replace(state_file, "#{JSON.pretty_generate(data.merge('schema' => STATE_SCHEMA))}\n")
      end

      def read_drift
        data = JSON.parse(Record::FS.read(drift_file))
        data.is_a?(Hash) ? data : nil
      rescue Errno::ENOENT, Errno::ENOTDIR, JSON::ParserError
        nil
      end

      def write_drift(data)
        Record::FS.mkdir_p(dir)
        Record::FS.replace(drift_file, "#{JSON.pretty_generate(data)}\n")
      end

      def append(record)
        Record::FS.mkdir_p(dir)
        Retention::Remove.write_line(log_file, JSON.generate({ "schema" => SCHEMA, "at" => Record::FS.rfc3339 }.merge(record)))
      end

      def receipts
        list = []
        Record::Reader.each(log_file) { |record| list << record if record["schema"] == SCHEMA }
        list
      end

      def exclusive
        Record::FS.mkdir_p(dir)
        File.open(File.join(dir, LOCK), LOCK_FLAGS, Record::Schemas::FILE_MODE) do |lock|
          return :busy unless lock.flock(File::LOCK_EX | File::LOCK_NB)

          yield
        end
      end

      def named_link_targets
        found = []
        applied = Cutover.latest_applied
        found.concat(Array(Cutover.load(applied["plan_id"]).dig("request", "link_targets"))) if applied
        found.concat(Array(read&.fetch("link_targets", nil)))
        found.uniq
      rescue OperationalFailure
        found.uniq
      end
    end
  end
end
