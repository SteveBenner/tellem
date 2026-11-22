# frozen_string_literal: true

require "time"
require_relative "../errors"
require_relative "../ids"
require_relative "../ports/backend"
require_relative "../record/formats"
require_relative "../record/fs"
require_relative "../record/reader"
require_relative "../record/scope"
require_relative "events"
require_relative "guard"
require_relative "lag"
require_relative "rows"

module Tellem
  module Backends
    class Mirror < Ports::Backend
      DB_DIR = File.expand_path("../../../db", __dir__)
      USAGE_LOCK = 7_164_823_392
      ROLLUP_SLICE = 400

      attr_reader :scope_root, :failure_next_command

      def initialize(scope_root: nil)
        super()
        @scope_root = scope_root
      end

      def guard_key
        "#{kind}|#{location}"
      end

      def guarded(breaker: true, &block)
        Guard.run(guard_key, retryable: method(:retryable?), sanitize: sanitizer, on_failure: method(:after_failure), breaker: breaker, &block)
      end

      def after_failure(_error)
        nil
      end

      def provision(location:, install_driver:)
        raise CapabilityUnavailable.new("TELLEM_BACKEND_DISABLED=1 blocks provisioning", next_command: "unset TELLEM_BACKEND_DISABLED") if Guard.disabled?

        prepare_driver(install_driver)
        prepare_storage
        result = guarded { |_| migrate }
        raise OperationalFailure.new("provisioning the #{kind} mirror failed: #{result.error}", next_command: "tellem store status") unless result.ok?

        status.merge(location_kind: location)
      end

      def sync(scope_id:, observations:)
        return { applied: 0, skipped: 0, disabled: true } if Guard.disabled?

        totals = { applied: 0, skipped: 0, failures: 0, attempts: [] }
        Array(observations).each_slice(SYNC_BATCH) do |batch|
          result = guarded do |_|
            schema_ready!
            write_batch(scope_id, batch)
          end
          totals[:attempts].concat(result.attempts)
          unless result.ok?
            totals.merge!(failures: totals[:failures] + 1, error: result.error, breaker: result.breaker)
            break
          end
          totals[:applied] += result.value
          totals[:skipped] += batch.size - result.value
        end
        totals
      end

      def feed(scope_root, force: false)
        Feed.new(self, scope_root).run(force: force)
      end

      def query(report:, params:)
        raise Declined.new("backend #{kind} is disabled") if Guard.disabled?

        require_relative "reports"
        result = guarded do |_|
          schema_ready!
          Reports.run(self, report.to_s, params || {})
        end
        raise Declined.new("backend #{kind} could not answer #{report}: #{result.error}", next_command: failure_next_command) unless result.ok?

        result.value
      end

      def emit_synced(summary)
        Events.emit("tellem.backend.synced", {
                      "kind" => kind, "location" => location, "rows_applied" => summary[:applied].to_i,
                      "lag_seconds" => summary[:lag_seconds], "duration_ms" => summary[:duration_ms],
                      "failures" => summary[:failures].to_i, "breaker" => summary[:breaker]
                    })
      end

      def body_cast
        {}
      end

      def true_literal
        "TRUE"
      end

      def false_literal
        "FALSE"
      end
    end
  end
end

require_relative "mirror/schema"
require_relative "mirror/rollup"
require_relative "mirror/writes"
require_relative "mirror/maintenance"
require_relative "feed"
