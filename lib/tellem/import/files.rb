# frozen_string_literal: true

require "digest"
require "json"
require "time"
require_relative "../record/fs"

module Tellem
  module Import
    module Files
      CHUNK = 1024 * 1024
      HEAD_BYTES = 64 * 1024

      module_function

      def regular?(path)
        Record::FS.lstat(path)&.file? == true
      end

      def entry(path)
        digest = Digest::SHA256.new
        bytes = 0
        Record::FS.open_read(path) do |file|
          while (chunk = file.read(CHUNK))
            digest.update(chunk)
            bytes += chunk.bytesize
          end
        end
        { "path" => path, "bytes" => bytes, "sha256" => digest.hexdigest }
      end

      def read(path)
        Record::FS.read(path)
      end

      def head(path, bytes = HEAD_BYTES)
        Record::FS.open_read(path) { |file| file.read(bytes).to_s }
      end

      def each_line(path, &block)
        Record::FS.open_read(path) { |file| file.each_line("\n", &block) }
      end

      def first_line(path)
        Record::FS.open_read(path) { |file| file.gets("\n") }
      end

      def json_lines(path)
        list = []
        number = 0
        each_line(path) do |line|
          number += 1
          next if line.strip.empty?

          value = begin
            JSON.parse(line)
          rescue JSON::ParserError, EncodingError
            nil
          end
          list << [number, value]
        end
        list
      end

      def utc_ms(time)
        time.utc.strftime("%Y-%m-%dT%H:%M:%S.%LZ")
      end

      def iso_ms(text)
        return nil unless text.is_a?(String) && !text.empty?

        utc_ms(Time.iso8601(text))
      rescue ArgumentError
        nil
      end

      def jsonl(dir)
        Dir.glob(File.join(dir, "**", "*.jsonl")).select { |path| regular?(path) }.sort
      end
    end
  end
end
