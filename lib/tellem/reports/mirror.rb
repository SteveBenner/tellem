# frozen_string_literal: true

require_relative "../backends/lag"
require_relative "../backends/selector"
require_relative "../errors"
require_relative "../ports/backend"
require_relative "../seams"

module Tellem
  module Reports
    module Mirror
      module_function

      def selector
        impl = Seams.fetch(:backend)
        impl.respond_to?(:for) ? impl : nil
      end

      def adapters(scopes)
        chooser = selector
        return nil if chooser.nil? || scopes.empty?

        scopes.map { |scope| chooser.for(scope["root"]) }
      rescue Tellem::Error
        nil
      end

      def current(scopes)
        list = adapters(scopes)
        return nil if list.nil?

        kinds = list.map { |adapter| [adapter.kind, adapter.respond_to?(:location) ? adapter.location : nil] }.uniq
        return nil unless kinds.size == 1 && kinds.first.first != "none"

        adapter = list.first
        status = adapter.status
        return nil unless status[:reachable] && status[:provisioned]

        lags = Array(status[:scopes]).to_h { |entry| [entry["scope_id"], entry] }
        current = scopes.all? do |scope|
          entry = lags[scope["scope_id"]] || Backends::Lag.scope_lag(scope["scope_id"], scope["root"], {}, nil, Time.now)
!entry["gone"] && entry["lag_seconds"].is_a?(Integer) && entry["lag_seconds"].zero?
        end
        return adapter if current

        release(list)
        nil
      rescue StandardError
        release(list)
        nil
      end

      def release(list)
        Array(list).each { |adapter| adapter.close if adapter.respond_to?(:close) }
      rescue StandardError
        nil
      end

      def query(adapter, report, params)
        adapter.query(report: report, params: params)
      rescue Ports::Backend::Declined, Tellem::CapabilityUnavailable
        nil
      end
    end
  end
end
