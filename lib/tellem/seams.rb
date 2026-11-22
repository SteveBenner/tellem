# frozen_string_literal: true

require_relative "errors"

module Tellem
  module Seams
    NAMES = %i[places remote workspace ingest_claude ingest_codex markdown identity projections backend deriver].freeze

    OWNERS = {
      places: "slice_1_places",
      remote: "slice_1_places",
      workspace: "slice_1_places",
      ingest_claude: "slice_1_ingest",
      ingest_codex: "slice_1_ingest",
      markdown: "slice_1_ingest",
      identity: "slice_2_identity",
      projections: "slice_2_projections",
      backend: "slice_1_backends",
      deriver: "slice_2_deriver"
    }.freeze

    class Unavailable
      attr_reader :seam

      def initialize(seam)
        @seam = seam
      end

      def foundation_default?
        true
      end

      def available?
        false
      end

      def method_missing(method_name, *_args, **_kwargs)
        raise CapabilityUnavailable.new(
          "seam #{seam} has no implementation (#{method_name}); it is built by #{OWNERS.fetch(seam)}",
          next_command: "tellem doctor"
        )
      end

      def respond_to_missing?(_method_name, _include_private = false)
        true
      end
    end

    class UnknownIdentity
      def foundation_default?
        true
      end

      def available?
        true
      end

      def snapshot(harness:, session_id:)
        :unknown
      end

      def from_tool_result(text:, at:)
        nil
      end
    end

    class NoProjections
      def foundation_default?
        true
      end

      def available?
        true
      end

      def refresh(scope, **_options)
        nil
      end
    end

    @registered = {}

    module_function

    def register(name, impl)
      key = check(name)
      @registered[key] = impl
    end

    def fetch(name)
      key = check(name)
      @registered.fetch(key) { default(key) }
    end

    def registered?(name)
      @registered.key?(check(name))
    end

    def default(name)
      case name
      when :identity then UnknownIdentity.new
      when :projections then NoProjections.new
      when :backend
        require_relative "ports/backend"
        Ports::Backend::None.new
      else Unavailable.new(name)
      end
    end

    def check(name)
      key = name.to_sym
      raise ArgumentError, "unknown seam #{name}; known: #{NAMES.join(', ')}" unless NAMES.include?(key)

      key
    end

    def status
      NAMES.to_h { |name| [name.to_s, registered?(name) ? "registered" : "foundation_default"] }
    end
  end
end
