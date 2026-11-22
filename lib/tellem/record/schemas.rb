# frozen_string_literal: true

module Tellem
  module Record
    module Schemas
      SCOPE = "tellem.scope/v1"
      RAW = "tellem.raw/v1"
      DERIVED = "tellem.derived/v1"
      POINTER = "tellem.pointer/v1"
      HOME = "tellem.home/v1"
      PRUNE = "tellem.prune/v1"
      REPORT = "tellem.report/v1"
      ALL = [SCOPE, RAW, DERIVED, POINTER, HOME, PRUNE, REPORT].freeze

      SCOPE_DIR = ".tellem"
      GITIGNORE = "*\n"
      DIR_MODE = 0o700
      FILE_MODE = 0o600
    end
  end
end
