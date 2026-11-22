# frozen_string_literal: true

require_relative "tellem/version"
require_relative "tellem/errors"
require_relative "tellem/bounds"
require_relative "tellem/ids"
require_relative "tellem/redact"
require_relative "tellem/seams"
require_relative "tellem/ports/harness_paths"
require_relative "tellem/record/schemas"
require_relative "tellem/record/fs"
require_relative "tellem/record/kinds"
require_relative "tellem/record/formats"
require_relative "tellem/record/scope"
require_relative "tellem/record/hook_core"
require_relative "tellem/record/reader"
require_relative "tellem/record/writer"
require_relative "tellem/record/pointers"
require_relative "tellem/record/lock"
require_relative "tellem/record/registry"
require_relative "tellem/ports/backend"
require_relative "tellem/ports/harness" if defined?(Rplugin::Ports::Base)
require_relative "tellem/ports/identity" if defined?(Rplugin::Ports::Base)
require_relative "tellem/config/resolver"
require_relative "tellem/cli"

Dir.glob(File.join(__dir__, "tellem", "*", "register.rb")).sort.each { |path| require path }
