# frozen_string_literal: true

require_relative "../backends/rows"

module Tellem
  module Otel
    module ReportDetails
      module_function

      def apply(jobs, results, index)
        by_scope = Hash.new { |hash, key| hash[key] = {} }
        jobs.each_with_index do |(scope_id, _path), position|
          merge(by_scope[scope_id], results[position][2])
        end
        return if by_scope.each_value.all?(&:empty?)

        harness = index.fetch("harness")
        request = index.fetch("request_key")
        effort = index.fetch("effort")
        cost = index.fetch("cost_usd")
        jobs.each_with_index do |(scope_id, _path), position|
          details = by_scope[scope_id]
          next if details.empty?

          results[position][0].each do |tuple|
            found = details[[tuple[harness], tuple[request]]]
            next unless found

            tuple[effort] ||= found[2]
            tuple[cost] = found[3]
          end
        end
      end

      def merge(details, found)
        return if found.nil?

        found.each { |key, entry| keep(details, key, entry) }
      end

      def remember(details, record)
        key = Backends::Rows.detail_key(record)
        return unless key

        _request_key, effort, units = Backends::Rows.detail(record["body"])
        keep(details, key, [record["ts"].to_s, record["session_key"].to_s, effort, units])
      end

      def keep(details, key, entry)
        current = details[key]
        details[key] = entry if current.nil? || (entry[0, 2] <=> current[0, 2]).negative?
      end
    end
  end
end
