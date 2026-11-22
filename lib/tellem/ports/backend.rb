# frozen_string_literal: true

require_relative "../errors"

module Tellem
  module Ports
    class Backend
      KINDS = %w[none sqlite postgres].freeze
      LOCATIONS = %w[scope user].freeze
      SYNC_BATCH = 1000
      STATUS_KEYS = %i[kind location schema_version rows lag_seconds last_sync_at reachable breaker].freeze

      class Declined < Tellem::Error
        CODE = "capability_unavailable"
      end

      def kind
        raise NotImplementedError, "#{self.class} must define kind"
      end

      def provision(location:, install_driver:)
        unavailable(:provision)
      end

      def status
        unavailable(:status)
      end

      def sync(scope_id:, observations:)
        unavailable(:sync)
      end

      def rebuild(scopes:)
        unavailable(:rebuild)
      end

      def drop(confirm:)
        unavailable(:drop)
      end

      def query(report:, params:)
        raise Declined.new("backend #{kind} does not answer report #{report}")
      end

      def self.status_record(**fields)
        STATUS_KEYS.to_h { |key| [key, fields[key]] }
      end

      private

      def unavailable(operation)
        raise Tellem::CapabilityUnavailable.new(
          "backend #{kind} does not support #{operation}",
          next_command: "tellem store provision sqlite|postgres"
        )
      end

      class None < Backend
        def kind
          "none"
        end

        def provision(location:, install_driver:)
          raise Tellem::CapabilityUnavailable.new(
            "no backend adapter is installed for provisioning",
            next_command: "tellem doctor"
          )
        end

        def status
          Backend.status_record(kind: "none", location: nil, schema_version: nil, rows: 0, lag_seconds: nil,
                                last_sync_at: nil, reachable: false, breaker: "closed")
        end

        def sync(scope_id:, observations:)
          { applied: 0, skipped: 0 }
        end

        def rebuild(scopes:)
          status
        end

        def drop(confirm:)
          status
        end
      end
    end
  end
end
