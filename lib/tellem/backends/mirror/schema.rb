# frozen_string_literal: true

require_relative "../../errors"
require_relative "../../ports/backend"
require_relative "../../record/fs"
require_relative "statements"

module Tellem
  module Backends
    class Mirror < Ports::Backend
      def migrations
        Dir.glob(File.join(DB_DIR, kind, "[0-9][0-9][0-9]_*.sql")).sort.map do |path|
          [File.basename(path)[0, 3].to_i, File.read(path)]
        end
      end

      def migrate
        transaction do
          lock_migrations
          current = table_exists?("tellem_meta") ? meta("schema_version").to_i : 0
          migrations.each do |version, sql|
            next if version <= current

            exec_script(sql)
            after_migration(version)
            put_meta("schema_version", version.to_s)
            current = version
          end
          put_meta("created_at", Record::FS.rfc3339) if meta("created_at").nil?
          current
        end
      end

      def lock_migrations
        nil
      end

      def after_migration(version)
        return unless version == 2

        recompute_rollup
      end

      def latest_schema
        @latest_schema ||= migrations.map(&:first).max.to_i
      end

      def schema_state(version)
        return nil if version.nil?
        return "ahead" if version > latest_schema

        version < latest_schema ? "behind" : "current"
      end

      def ahead_message(version)
        "the #{kind} mirror is at schema #{version}, newer than this tellem's #{latest_schema}; reports use files and the feed pauses"
      end

      def ensure_schema
        return :current if @schema_current

        @failure_next_command = nil
        version = table_exists?("tellem_meta") ? meta("schema_version")&.to_i : nil
        return :absent if version.nil?
        return :ahead if version > latest_schema

        migrate_on_use if version < latest_schema
        @schema_current = true
        :current
      end

      def migrate_on_use
        migrate
      rescue StandardError => e
        raise if retryable?(e)

        @failure_next_command = "tellem store provision #{kind}"
        raise OperationalFailure.new("migrating the #{kind} mirror to schema #{latest_schema} failed: #{e.message.to_s.lines.first.to_s.strip}",
                                     next_command: @failure_next_command), cause: nil
      end

      def schema_ready!
        version = ensure_schema
        return if version == :current

        current = meta("schema_version") if version == :ahead
        raise CapabilityUnavailable.new(ahead_message(current), next_command: "tellem version") if version == :ahead

        raise CapabilityUnavailable.new("the #{kind} mirror is not provisioned", next_command: "tellem store provision #{kind}")
      end

      def meta(key)
        rows = select(statement("SELECT value FROM tellem_meta WHERE key = ?"), [key])
        rows.first && rows.first["value"]
      end

      def put_meta(key, value)
        execute(insert_statement("tellem_meta", %w[key value], 1, conflict: "key", update: %w[value]), [key, value])
      end
    end
  end
end
