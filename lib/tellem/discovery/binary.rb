# frozen_string_literal: true

require_relative "bounds"

module Tellem
  module Discovery
    module Binary
      CHUNK = 4 * 1024 * 1024
      MAX_BYTES = 2 * 1024 * 1024 * 1024
      SECONDS = 40

      module_function

      def scan(path, needles)
        return { found: {}, reason: "no binary on the search path" } unless path

        info = Bounds.stat(path)
        return { found: {}, reason: "#{path} is not a regular file" } unless info&.file?
        return { found: {}, reason: "#{path} is larger than the #{MAX_BYTES} byte bound" } if info.size > MAX_BYTES

        search(path, needles.map { |needle| needle.b }, Bounds.deadline(SECONDS))
      rescue SystemCallError, IOError => e
        { found: {}, reason: "#{path} could not be read: #{e.class}" }
      rescue Exceeded => e
        { found: {}, reason: e.message }
      end

      def search(path, needles, deadline)
        found = needles.to_h { |needle| [needle.dup.force_encoding(Encoding::UTF_8), false] }
        keep = (needles.map(&:bytesize).max || 1) - 1
        carry = "".b
        File.open(path, "rb") do |io|
          while (chunk = io.read(CHUNK))
            Bounds.check!(deadline, path)
            window = carry + chunk
            needles.each do |needle|
              key = needle.dup.force_encoding(Encoding::UTF_8)
              found[key] = true if !found[key] && window.include?(needle)
            end
            break if found.values.all?

            carry = window.byteslice([window.bytesize - keep, 0].max, keep)
          end
        end
        { found: found, reason: nil }
      end
    end
  end
end
