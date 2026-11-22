# frozen_string_literal: true

require_relative "../ids"
require_relative "../ports/harness_paths"
require_relative "../record/hook_core"
require_relative "../record/scope"

module Tellem
  module Import
    Candidate = Struct.new(:session_key, :harness, :session_id, :home_root, :source, :files, :data, keyword_init: true) do
      def items
        Array(data["items"]).size
      end
    end

    module Homes
      module_function

      def root_for(session_key, path)
        entry = Record::HookCore.read_home(File.join(Ports::HarnessPaths.homes_dir, session_key))
        return entry["root"] if entry && File.directory?(entry["root"])

        Record::Scope.locate(path)
      end
    end
  end
end
