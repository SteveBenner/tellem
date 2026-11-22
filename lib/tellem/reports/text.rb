# frozen_string_literal: true

require "json"

module Tellem
  module Reports
    module Text
      module_function

      def table(headers, rows)
        return "(no rows)" if rows.empty?

        widths = headers.each_index.map { |index| ([headers[index]] + rows.map { |row| row[index] }).map(&:length).max }
        lines = [headers, *rows].map do |row|
          row.each_with_index.map { |cell, index| cell.ljust(widths[index]) }.join("  ").rstrip
        end
        lines.join("\n")
      end

      def cell(value)
        case value
        when nil then "-"
        when Array then value.empty? ? "-" : value.join(",")
        when Hash then JSON.generate(value)
        else value.to_s
        end
      end

      def place(place)
        return "-" if place.nil?
        return "#{place['place_id']} (unknown place)" unless place["known"]

        where = place["real_path"] || place["host"] || place["place_id"]
        "#{place['kind']} #{where}"
      end

      def with_notes(body, notes)
        ([body] + Array(notes).compact).join("\n")
      end
    end
  end
end
