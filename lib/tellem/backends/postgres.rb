# frozen_string_literal: true

require "ipaddr"
require_relative "../errors"
require_relative "../ports/harness_paths"
require_relative "../version"
require_relative "driver"
require_relative "guard"
require_relative "mirror"
require_relative "rows"

module Tellem
  module Backends
    class Postgres < Mirror
      STRONG_SSL = %w[require verify-ca verify-full].freeze
      RETRYABLE = %w[
        PG::ConnectionBad PG::UnableToSend PG::AdminShutdown PG::CrashShutdown PG::CannotConnectNow PG::QueryCanceled
        PG::LockNotAvailable PG::SerializationFailure PG::TRDeadlockDetected PG::ConnectionException PG::ConnectionFailure
      ].freeze
      MIGRATION_LOCK = 7_164_823_391

      attr_reader :secret_name

      def initialize(secret_name:, scope_root: nil)
        super(scope_root: scope_root)
        @secret_name = secret_name.to_s
      end

      def kind
        "postgres"
      end

      def location
        @location ||= begin
          params = conninfo
          host = params["host"] || params["hostaddr"] || "local"
          "postgres://#{host}:#{params['port'] || 5432}/#{params['dbname'] || params['user'] || 'postgres'}"
        rescue Tellem::Error
          "postgres://secret:#{secret_name}"
        end
      end

      def url
        @url ||= fetch_url
      end

      def fetch_url
        Rplugin::Ports.for(Ports::HarnessPaths::PLUGIN_ID, root: Tellem.root).secrets.get(secret_name).to_s
      rescue Rplugin::MissingSecret
        raise CapabilityUnavailable.new(
          "no PostgreSQL URL in the secret #{secret_name}; store it through the SDK secrets port " \
          "(standalone: #{secret_name}: <url> in $XDG_CONFIG_HOME/rplugin/tellem/credentials.yml, mode 0600)",
          next_command: "tellem store provision postgres --secret #{secret_name}"
        ), cause: nil
      rescue Rplugin::Refused => e
        raise OperationalFailure.new(Guard.sanitizer.call(e.message), next_command: "chmod 600 the tellem credentials file"), cause: nil
      end

      def conninfo
        Driver.load!("postgres")
        ::PG::Connection.conninfo_parse(url).each_with_object({}) do |option, out|
          out[option[:keyword].to_s] = option[:val] unless option[:val].nil?
        end
      rescue ::PG::Error
        raise OperationalFailure.new("the PostgreSQL URL in secret #{secret_name} does not parse", next_command: "tellem store status"), cause: nil
      end

      def sanitizer
        @sanitizer ||= begin
          params = conninfo
          Guard.sanitizer(@url, params["password"])
        rescue Tellem::Error
          Guard.sanitizer(@url)
        end
      end

      def retryable?(error)
        RETRYABLE.include?(error.class.name) || error.is_a?(SystemCallError) || error.is_a?(IOError) ||
          (defined?(::PG::ConnectionBad) && error.is_a?(::PG::ConnectionBad))
      end

      def after_failure(error)
        reset if retryable?(error) || (defined?(::PG::Error) && error.is_a?(::PG::Error) && @conn&.status != ::PG::CONNECTION_OK)
      end

      def reset
        @conn&.close
      rescue StandardError
        nil
      ensure
        @conn = nil
      end

      alias close reset

      def prepare_driver(install)
        Driver.ensure!("postgres", install: install)
      end

      def storage_present?
        true
      end

      def prepare_storage
        url
        nil
      end

      def loopback?(params)
        hosts = [params["host"], params["hostaddr"]].compact.flat_map { |value| value.split(",") }.map(&:strip)
        return true if hosts.empty?

        hosts.all? do |host|
          next true if host.empty? || host.start_with?("/") || host == "localhost"

          begin
            IPAddr.new(host).loopback?
          rescue IPAddr::Error
            false
          end
        end
      end

      def connection_params
        params = conninfo
        params["connect_timeout"] = Guard::CONNECT_TIMEOUT_S.to_s
        params["application_name"] = "tellem"
        params["options"] = [params["options"], "-c statement_timeout=#{Guard::STATEMENT_TIMEOUT_MS}"].compact.join(" ")
        params["sslmode"] = "require" unless loopback?(params) || STRONG_SSL.include?(params["sslmode"])
        params["tcp_user_timeout"] = Guard::STATEMENT_TIMEOUT_MS.to_s if supports?("tcp_user_timeout")
        params
      end

      def supports?(keyword)
        @keywords ||= ::PG::Connection.conndefaults.map { |option| option[:keyword].to_s }
        @keywords.include?(keyword)
      end

      def conn
        return @conn if @conn && @conn.status == ::PG::CONNECTION_OK

        reset
        handle = ::PG::Connection.new(connection_params)
        handle.type_map_for_results = ::PG::BasicTypeMapForResults.new(handle)
        handle.type_map_for_queries = ::PG::BasicTypeMapForQueries.new(handle)
        handle.set_notice_processor { |_message| nil }
        @conn = handle
      end

      def ph(index)
        "$#{index}"
      end

      def body_cast
        { "body" => "::jsonb" }
      end

      def transaction(&block)
        return yield if @in_transaction

        conn.transaction do
          @in_transaction = true
          lock_usage
          result = block.call
          flush_dirty
          result
        ensure
          @in_transaction = false
        end
      end

      def lock_migrations
        conn.exec("SELECT pg_advisory_xact_lock(#{MIGRATION_LOCK})")
      end

      def table_exists?(name)
        !conn.exec_params("SELECT to_regclass($1)::text AS t", [name]).first["t"].nil?
      end

      def select(sql, params = [])
        conn.exec_params(sql, params).to_a
      end

      def execute(sql, params = [])
        conn.exec_params(sql, params).cmd_tuples
      end

      def exec_script(sql)
        conn.exec(sql)
      end

      def drop_targets
        Rows::TABLES.map { |table| "#{location} table #{table}" }
      end

      def drop_storage
        transaction { conn.exec("DROP TABLE IF EXISTS #{Rows::TABLES.join(', ')}") }
        true
      end
    end
  end
end
