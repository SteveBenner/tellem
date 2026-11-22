# frozen_string_literal: true

require "json"
require "digest"
require_relative "errors"

module Tellem
  module Ids
    HARNESSES = %w[claude codex].freeze
    SESSION_ID = /\A[A-Za-z0-9_-]{1,200}\z/
    AGENT_ID_MAX = 128
    AGENT_KEY = /\A[A-Za-z0-9_-]{1,128}\z/
    MAIN_AGENT = "main"

    module_function

    def canonical_json(value)
      JSON.generate(canonical(value))
    end

    def canonical(value)
      case value
      when Hash
        value.keys.map(&:to_s).sort.each_with_object({}) do |key, out|
          out[key] = canonical(value.key?(key) ? value[key] : value[key.to_sym])
        end
      when Array then value.map { |item| canonical(item) }
      when Float then raise InvalidRecord.new("float in identity field")
      when Symbol then value.to_s
      when String then value.encode("UTF-8")
      when Integer, true, false, nil then value
      else raise InvalidRecord.new("unsupported identity value #{value.class}")
      end
    end

    def sha256(text)
      Digest::SHA256.hexdigest(text)
    end

    def scope_id(host, root)
      sha256("#{host}\0#{root}")[0, 16]
    end

    def place_id(identity)
      sha256(canonical_json(identity))[0, 24]
    end

    def repository_id(host, common_dir)
      sha256(canonical_json([host, common_dir]))[0, 24]
    end

    def observation_id(schema, kind, identity)
      sha256(canonical_json([schema, kind, *identity]))[0, 32]
    end

    def raw_id(harness:, session_id:, agent_key:, event:, tool_use_id:, ts_ns:, pid:)
      sha256(canonical_json([harness, session_id, agent_key, event, tool_use_id || "", ts_ns, pid]))[0, 32]
    end

    def counters_digest(counters)
      sha256(canonical_json(counters))[0, 32]
    end

    def session_key(harness, session_id)
      return nil unless HARNESSES.include?(harness.to_s)
      return nil unless session_id.is_a?(String) && SESSION_ID.match?(session_id)

      "#{harness}-#{session_id}"
    end

    def agent_key(agent_id)
      return MAIN_AGENT if agent_id.nil? || agent_id == ""

      filtered = agent_id.to_s.gsub(/[^A-Za-z0-9_-]/, "")[0, AGENT_ID_MAX]
      filtered.nil? || filtered.empty? ? nil : filtered
    end

    def valid_session_key?(key)
      harness, session_id = key.to_s.split("-", 2)
      !session_key(harness, session_id).nil?
    end

    def valid_agent_key?(key)
      key.is_a?(String) && AGENT_KEY.match?(key)
    end
  end
end
