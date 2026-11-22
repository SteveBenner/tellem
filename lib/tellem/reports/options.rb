# frozen_string_literal: true

require "time"
require_relative "../errors"

module Tellem
  module Reports
    module Options
      CANONICAL = "%Y-%m-%dT%H:%M:%S.%LZ"
      DATE = /\A\d{4}-\d{2}-\d{2}\z/

      module_function

      def parse(args, usage:, values: [], flags: [], positional: 0..0)
        list = args.dup
        options = {}
        rest = []
        until list.empty?
          item = list.shift
          if values.include?(item)
            value = list.shift
            raise UsageError.new("#{item} needs a value: #{usage}") if value.nil? || value.start_with?("--")

            options[key(item)] = value
          elsif flags.include?(item)
            options[key(item)] = true
          elsif item.start_with?("--")
            raise UsageError.new("unknown argument #{item}: #{usage}")
          else
            rest << item
          end
        end
        raise UsageError.new(usage) unless positional.cover?(rest.size)

        [options, rest]
      end

      def key(flag)
        flag.delete_prefix("--").tr("-", "_").to_sym
      end

      def time_bound(value, name)
        return nil if value.nil?

        time = if DATE.match?(value)
                 Time.utc(*value.split("-").map { |part| Integer(part, 10) })
               else
                 Time.iso8601(value)
               end
        time.utc.strftime(CANONICAL)
      rescue ArgumentError
        raise UsageError.new("#{name} must be an RFC 3339 time or a YYYY-MM-DD date, not #{value}")
      end

      def duration(value)
        match = /\A(\d+)([smhdw])\z/.match(value.to_s)
        raise UsageError.new("duration must be a number with s, m, h, d, or w, such as 30d, not #{value}") unless match

        match[1].to_i * { "s" => 1, "m" => 60, "h" => 3600, "d" => 86_400, "w" => 604_800 }.fetch(match[2])
      end

      def size(value)
        match = /\A(\d+)(?:([KMGT])(i?B)?|B)?\z/i.match(value.to_s)
        raise UsageError.new("size must be bytes or a number with K, M, G, or T, such as 500M, not #{value}") unless match

        power = match[2] ? %w[K M G T].index(match[2].upcase) + 1 : 0
        match[1].to_i * (1024**power)
      end
    end
  end
end
