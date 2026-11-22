# frozen_string_literal: true

require_relative "../seams"
require_relative "selector"

Tellem::Seams.register(:backend, Tellem::Backends::Selector.new)
