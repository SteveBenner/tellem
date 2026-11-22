# frozen_string_literal: true

require "json"
require_relative "errors"

module Tellem
  module Bounds
    RECORD_BYTES = 8_388_608
    NESTING_DEPTH = 64
    TOOL_PAYLOAD_BYTES = 262_144
    RAW_LINE_BYTES = 65_536
    RAW_PATHS = 16
    RAW_PATH_BYTES = 4096
    READ_CHUNK = 65_536

    LIMITS = {
      record_bytes: RECORD_BYTES,
      nesting_depth: NESTING_DEPTH,
      tool_payload_bytes: TOOL_PAYLOAD_BYTES,
      raw_line_bytes: RAW_LINE_BYTES
    }.freeze

    module_function

    def limit(name)
      LIMITS.fetch(name)
    end

    def read_bounded(io, max_bytes = RECORD_BYTES)
      data = +""
      total = 0
      while (chunk = io.read(READ_CHUNK))
        total += chunk.bytesize
        room = max_bytes - data.bytesize
        data << chunk.byteslice(0, room) if room.positive?
      end
      [data, total > max_bytes, total]
    end

    def check_bytes(bytesize, name)
      return bytesize if bytesize <= limit(name)

      raise InputTooLarge.new("#{name} bound exceeded", detail: { "limit" => limit(name), "bytes" => bytesize })
    end

    def parse_json(text, limit_name = :record_bytes)
      check_bytes(text.bytesize, limit_name)
      JSON.parse(text, max_nesting: NESTING_DEPTH)
    rescue JSON::NestingError
      raise InputTooLarge.new("nesting_depth bound exceeded", detail: { "limit" => NESTING_DEPTH }), cause: nil
    rescue JSON::ParserError
      raise InvalidInput.new("malformed JSON", detail: { "bytes" => text.bytesize }), cause: nil
    end

    def tool_payload_over?(payload)
      size = payload.is_a?(String) ? payload.bytesize : JSON.generate(payload).bytesize
      size > TOOL_PAYLOAD_BYTES
    end

    def clip_paths(paths)
      Array(paths).select { |path| path.is_a?(String) && !path.empty? && path.bytesize <= RAW_PATH_BYTES }.first(RAW_PATHS)
    end
  end
end
