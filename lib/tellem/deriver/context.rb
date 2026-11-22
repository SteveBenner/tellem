# frozen_string_literal: true

require_relative "../version"
require_relative "../config/resolver"
require_relative "../seams"
require_relative "../ports/harness_paths"
require_relative "../record/fs"
require_relative "../record/scope"
require_relative "cursor"

module Tellem
  module Deriver
    class Context
      DEFAULT_TIMEOUT_MS = 2000

      attr_reader :root, :scope_id, :cursor, :timeout_ms, :started_ns

      def initialize(root)
        @root = root
        @started_ns = Record::FS.now_ns
        @scope_id = Record::Scope.open(root)["scope_id"]
        @cursor = Cursor.load(root)
        @flags = {}
        @resolved = {}
        @samples = {}
        value = Config.get("workspace.sample_timeout_ms", scope: root)
        @timeout_ms = value.is_a?(Integer) && value.positive? ? value : DEFAULT_TIMEOUT_MS
      end

      def flag?(key)
        @flags.fetch(key) { @flags[key] = Config.get(key, scope: root) == true }
      end

      def seam(name)
        Seams.fetch(name)
      end

      def harness
        @harness ||= Rplugin::Ports.for(Ports::HarnessPaths::PLUGIN_ID, root: Tellem.root).harness
      end

      def spawn_tools(harness_name)
        Ports::HarnessPaths.spawn_tools(harness_name)
      end

      def resolve(path, base: nil, repository: true)
        key = [path, base, repository]
        @resolved.fetch(key) do
          @resolved[key] = seam(:places).resolve(path, base: base, timeout_ms: timeout_ms, repository: repository)
        end
      end

      def repository(path)
        key = [:repository, path]
        @resolved.fetch(key) { @resolved[key] = seam(:places).repository(path, timeout_ms: timeout_ms) }
      end

      def git_lookup
        @git_lookup ||= seam(:places).git_remote_lookup(timeout_ms: timeout_ms)
      end

      def sample(tree)
        @samples.fetch(tree) { @samples[tree] = seam(:workspace).sample(tree, timeout_ms: timeout_ms) }
      end
    end
  end
end
