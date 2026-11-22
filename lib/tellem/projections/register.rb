# frozen_string_literal: true

require_relative "../seams"
require_relative "run"

Tellem::Seams.register(:projections, Tellem::Projections::Run.new)
