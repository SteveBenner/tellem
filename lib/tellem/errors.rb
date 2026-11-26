# frozen_string_literal: true

module Tellem
  EXIT_CODES = {
    ok: 0,
    operational_failure: 1,
    usage: 2,
    confirmation_required: 3,
    busy: 4,
    capability_unavailable: 5
  }.freeze

  class Error < StandardError
    CODE = "operational_failure"

    attr_reader :next_command, :detail

    def initialize(message = nil, next_command: nil, detail: nil)
      @next_command = next_command
      @detail = detail
      super(message || self.class::CODE.tr("_", " "))
    end

    def code
      self.class::CODE
    end

    def exit_code
      EXIT_CODES.fetch(code.to_sym, EXIT_CODES[:operational_failure])
    end

    def to_h
      { "code" => code, "message" => message, "next_command" => next_command, "detail" => detail }.compact
    end
  end

  class OperationalFailure < Error
    CODE = "operational_failure"
  end

  class UsageError < Error
    CODE = "usage"
  end

  class ConfirmationRequired < Error
    CODE = "confirmation_required"
  end

  class Busy < Error
    CODE = "busy"
  end

  class CapabilityUnavailable < Error
    CODE = "capability_unavailable"
  end

  class InvalidInput < Error
    CODE = "operational_failure"
  end

  class InputTooLarge < Error
    CODE = "operational_failure"
  end

  class InvalidRecord < Error
    CODE = "operational_failure"
  end

  class SymlinkRefused < Error
    CODE = "operational_failure"
  end

  class PermissionDenied < Error
    CODE = "operational_failure"
  end
end
