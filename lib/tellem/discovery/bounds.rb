# frozen_string_literal: true

module Tellem
  module Discovery
    class Exceeded < StandardError; end

    module Bounds
      TEXT_BYTES = 1024 * 1024
      CODE_BYTES = 256 * 1024
      SOURCE_SECONDS = 20
      ENTRY_LIMIT = 400_000
      REFUSED_NAMES = /\A(?:\.credentials\.json|auth\.json|auth\.lock|credentials(?:\.[a-z]+)?|\.netrc|id_[a-z0-9]+|.+\.pem|.+\.key)\z/i.freeze
      REFUSED_SUFFIXES = %w[.jsonl .zst .sqlite .sqlite3 .db .wal .shm].freeze

      module_function

      def now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def deadline(seconds = SOURCE_SECONDS)
        now + seconds
      end

      def check!(deadline, what)
        raise Exceeded, "#{what} exceeded its time bound" if now > deadline
      end

      def refused?(path)
        name = File.basename(path)
        REFUSED_NAMES.match?(name) || REFUSED_SUFFIXES.any? { |suffix| name.end_with?(suffix) }
      end

      def lstat(path)
        File.lstat(path)
      rescue SystemCallError
        nil
      end

      def stat(path)
        File.stat(path)
      rescue SystemCallError
        nil
      end

      def text(path, limit: TEXT_BYTES)
        return nil if refused?(path)

        info = stat(path)
        return nil unless info&.file? && info.size <= limit

        data = File.open(path, "rb") { |io| io.read(limit + 1) }.to_s.dup
        return nil if data.bytesize > limit || data.include?("\0")

        data.force_encoding(Encoding::UTF_8)
        data.valid_encoding? ? data : data.encode("UTF-8", "binary", invalid: :replace, undef: :replace)
      rescue SystemCallError, IOError
        nil
      end

      def children(path)
        Dir.children(path).sort
      rescue SystemCallError
        []
      end

      def walk(root, deadline:, skip: [], limit: ENTRY_LIMIT)
        return 0 unless lstat(root)&.directory?

        stack = [root]
        seen = 0
        until stack.empty?
          dir = stack.pop
          children(dir).each do |name|
            seen += 1
            raise Exceeded, "#{root} holds more than #{limit} entries" if seen > limit

            check!(deadline, root) if (seen % 512).zero?
            path = File.join(dir, name)
            info = lstat(path)
            next unless info

            if info.directory?
              stack << path unless skip.include?(name)
            elsif info.file?
              yield path, info
            end
          end
        end
        seen
      end

      def real(path)
        File.realpath(path)
      rescue SystemCallError
        nil
      end
    end
  end
end
