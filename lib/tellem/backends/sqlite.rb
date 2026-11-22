# frozen_string_literal: true

require_relative "../errors"
require_relative "../record/fs"
require_relative "../record/schemas"
require_relative "driver"
require_relative "guard"
require_relative "mirror"

module Tellem
  module Backends
    class Sqlite < Mirror
      SIDECARS = %w[-wal -shm -journal].freeze
      PAGE_SIZE = 65_536

      attr_reader :path

      def initialize(path:, scope_root: nil)
        super(scope_root: scope_root)
        @path = path
      end

      def kind
        "sqlite"
      end

      def location
        path
      end

      def sanitizer
        @sanitizer ||= Guard.sanitizer
      end

      def retryable?(error)
        defined?(::SQLite3::BusyException) && (error.is_a?(::SQLite3::BusyException) || error.is_a?(::SQLite3::LockedException))
      end

      def prepare_driver(install)
        Driver.ensure!("sqlite", install: install)
      end

      def storage_present?
        stat = Record::FS.lstat(path)
        raise SymlinkRefused.new("symlinked mirror refused", detail: { "path" => path }) if stat&.symlink?

        !stat.nil? && stat.file?
      end

      def prepare_storage
        Record::FS.mkdir_p(File.dirname(path))
        return if storage_present?

        File.open(path, File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW, Record::Schemas::FILE_MODE, &:fsync)
        Record::FS.fsync_dir(File.dirname(path))
      rescue Errno::EEXIST
        nil
      end

      def db
        return @db if @db

        Driver.load!("sqlite")
        raise CapabilityUnavailable.new("the sqlite mirror is not provisioned", next_command: "tellem store provision sqlite") unless storage_present?

        previous = File.umask(0o077)
        begin
          handle = ::SQLite3::Database.new(path)
          handle.busy_timeout = Guard::BUSY_TIMEOUT_MS
          handle.results_as_hash = true
          handle.execute("PRAGMA page_size=#{PAGE_SIZE}")
          handle.execute("PRAGMA journal_mode=WAL")
          handle.execute("PRAGMA foreign_keys=OFF")
        ensure
          File.umask(previous)
        end
        tighten
        @db = handle
      end

      def tighten
        ([path] + SIDECARS.map { |suffix| "#{path}#{suffix}" }).each do |file|
          stat = Record::FS.lstat(file)
          File.chmod(Record::Schemas::FILE_MODE, file) if stat&.file? && (stat.mode & 0o777) != Record::Schemas::FILE_MODE
        end
      end

      def close
        @statements&.each_value { |statement| statement.close unless statement.closed? }
        @statements = nil
        @db&.close
        @db = nil
      end

      def ph(_index)
        "?"
      end

      def true_literal
        "1"
      end

      def false_literal
        "0"
      end

      def bind(values)
        values.map do |value|
          case value
          when true then 1
          when false then 0
          else value
          end
        end
      end

      def transaction(&block)
        return yield if db.transaction_active?

        db.transaction(:immediate) do
          result = block.call
          flush_dirty
          result
        end
      end

      def table_exists?(name)
        !db.execute("SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?", [name]).empty?
      end

      def select(sql, params = [])
        db.execute(sql, bind(params))
      end

      def execute(sql, params = [])
        db.execute(sql, bind(params))
        db.changes
      end

      def exec_script(sql)
        db.execute_batch(sql)
      end

      def insert(table, columns, rows, conflict:, update: nil, cast: {})
        return 0 if rows.empty?

        statement = prepared(Rows.insert_sql(table, columns, 1, conflict: conflict, update: update, placeholder: method(:ph), cast: cast))
        rows.sum do |row|
          statement.execute(*bind(row))
          db.changes
        end
      end

      def prepared(sql)
        @statements ||= {}
        statement = @statements[sql]
        statement = @statements[sql] = db.prepare(sql) if statement.nil? || statement.closed?
        statement.reset!
        statement
      end

      def drop_targets
        [path] + SIDECARS.map { |suffix| "#{path}#{suffix}" }.select { |file| Record::FS.lexists?(file) }
      end

      def drop_storage
        close
        ([path] + SIDECARS.map { |suffix| "#{path}#{suffix}" }).each { |file| Record::FS.unlink_quiet(file) }
        Record::FS.fsync_dir(File.dirname(path))
        true
      end
    end
  end
end
