# frozen_string_literal: true

require "etc"

module Tellem
  module Ports
    module HarnessPaths
      PLUGIN_ID = "tellem"
      SPAWN_TOOLS = {
        "claude" => %w[Task Agent].freeze,
        "codex" => %w[spawn_agent].freeze
      }.freeze

      module_function

      def rplugin_home
        value = ENV["RPLUGIN_HOME"]
        File.expand_path(value && !value.empty? ? value : "~/.rplugin")
      end

      def rplugin_paths
        return Rplugin::Paths if defined?(Rplugin::Paths)

        require File.join(rplugin_home, "lib", "rplugin", "paths.rb")
        Rplugin::Paths
      end

      def state_dir
        value = ENV["TELLEM_STATE_HOME"]
        return File.expand_path(value) if value && !value.empty?

        File.join(rplugin_paths.state_home, PLUGIN_ID)
      end

      def isolated_state?
        value = ENV["TELLEM_STATE_HOME"]
        !value.nil? && !value.empty?
      end

      def user_scope_root
        File.join(state_dir, "user")
      end

      def homes_dir
        File.join(state_dir, "homes")
      end

      def registry_stream
        File.join(state_dir, "registry.jsonl")
      end

      def capture_flag
        File.join(state_dir, "capture.enabled")
      end

      def exclude_roots_file
        File.join(state_dir, "scope.exclude_roots")
      end

      def capture_settled
        File.join(state_dir, "capture.settled")
      end

      def capture_fsync_flag
        File.join(state_dir, "capture.fsync")
      end

      def hook_gaps
        File.join(state_dir, "hook-gaps.jsonl")
      end

      def user_mirror
        File.join(state_dir, "mirror.sqlite3")
      end

      def backend_breaker
        File.join(state_dir, "backend-breaker.json")
      end

      def cutover_dir
        File.join(state_dir, "cutover")
      end

      def body_spool
        File.join(state_dir, "bodies")
      end

      def claude_home
        rplugin_paths.claude_home
      end

      def claude_credentials
        File.join(claude_home, ".credentials.json")
      end

      def claude_projects
        File.join(claude_home, "projects")
      end

      def codex_home
        value = ENV["CODEX_HOME"]
        File.expand_path(value && !value.empty? ? value : "~/.codex")
      end

      def codex_sessions
        File.join(codex_home, "sessions")
      end

      def ai_home
        value = ENV["TELLEM_AI_HOME"]
        candidate = File.expand_path(value && !value.empty? ? value : "~/.ai")
        File.directory?(candidate) ? candidate : nil
      end

      def spawn_tools(harness)
        SPAWN_TOOLS.fetch(harness.to_s, [].freeze)
      end

      def home
        value = ENV["HOME"]
        return File.expand_path(value) unless value.to_s.empty?

        File.expand_path(Etc.getpwuid&.dir || "/")
      rescue ArgumentError
        "/"
      end

      def config_home
        value = ENV["XDG_CONFIG_HOME"]
        File.expand_path(value && !value.empty? ? value : File.join(home, ".config"))
      end

      def specstory_home
        File.join(home, ".specstory")
      end

      def scope_roots
        require_relative "../record/reader"
        roots = Record::Reader.records(registry_stream).first.filter_map do |entry|
          entry["root"] if entry.is_a?(Hash) && entry["kind"] != "user" && entry["root"].is_a?(String) && File.directory?(entry["root"])
        end
        roots.uniq.sort
      end

      def discovery_paths
        {
          home: home, config_home: config_home, claude_home: claude_home, codex_home: codex_home, ai_home: ai_home,
          specstory_home: specstory_home, plugins_home: rplugin_paths.plugins_home, managed_settings: "/etc/claude-code/managed-settings.json",
          path: ENV.fetch("PATH", ""), scopes: scope_roots
        }
      end

      def all
        {
          state_dir: state_dir,
          user_scope_root: user_scope_root,
          homes_dir: homes_dir,
          registry_stream: registry_stream
        }
      end
    end
  end
end
