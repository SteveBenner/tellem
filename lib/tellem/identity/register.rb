# frozen_string_literal: true

require_relative "../seams"
require_relative "binding"
require_relative "timeline"

Tellem::Seams.register(:identity, Tellem::Identity::Binding.new)
