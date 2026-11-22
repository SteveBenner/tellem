# frozen_string_literal: true

require_relative "../seams"
require_relative "local"
require_relative "workspace"
require_relative "remote"

Tellem::Seams.register(:places, Tellem::Places::Local)
Tellem::Seams.register(:workspace, Tellem::Places::Workspace)
Tellem::Seams.register(:remote, Tellem::Places::Remote)
