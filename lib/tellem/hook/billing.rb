# frozen_string_literal: true

require_relative "../ports/harness_paths"

module Tellem
  module Hook
    module Billing
      UNKNOWN = "unknown"

      module_function

      def detect(harness, env: ENV)
        harness == "codex" ? codex(env) : claude(env)
      end

      def claude(env)
        return "api" if set?(env, "ANTHROPIC_API_KEY") || set?(env, "ANTHROPIC_AUTH_TOKEN")
        return "bedrock" if env["CLAUDE_CODE_USE_BEDROCK"] == "1"
        return "vertex" if env["CLAUDE_CODE_USE_VERTEX"] == "1"

        credentials? ? "subscription" : UNKNOWN
      end

      def codex(env)
        set?(env, "OPENAI_API_KEY") ? "api" : UNKNOWN
      end

      def set?(env, name)
        value = env[name]
        value.is_a?(String) && !value.empty?
      end

      def credentials?
        File.lstat(Ports::HarnessPaths.claude_credentials)
        true
      rescue SystemCallError, LoadError, NameError
        false
      end
    end
  end
end
