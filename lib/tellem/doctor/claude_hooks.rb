# frozen_string_literal: true

require "json"
require_relative "../version"
require_relative "../ports/harness_paths"
require_relative "../record/fs"
require_relative "entry"

module Tellem
  module Doctor
    module ClaudeHooks
      CHECK = "claude_hooks"
      PLUGIN_KEY = "tellem@tellem"
      RUNNER = "tellem-hook"
      MAX_BYTES = 1024 * 1024
      ASYNC_TIMEOUT_S = 30
      SYNC_TIMEOUT_S = 2
      CAPTURE = {
        "SessionStart" => "session_start",
        "UserPromptSubmit" => "prompt_submit",
        "PostToolUse" => "post_tool",
        "PostToolUseFailure" => "post_tool",
        "SubagentStart" => "subagent_start",
        "SubagentStop" => "subagent_stop"
      }.freeze
      SYNCHRONOUS = { "Stop" => "stop", "SessionEnd" => "session_end" }.freeze

      module_function

      def check
        files = rendered_files
        return [not_installed] if files.empty?

        files.flat_map { |file| inspect_file(file) }
      end

      def rplugin_bin
        File.join(Ports::HarnessPaths.rplugin_home, "bin", "rplugin")
      end

      def repackage
        "#{rplugin_bin} package tellem && #{rplugin_bin} install tellem"
      end

      def installed_list
        File.join(Ports::HarnessPaths.claude_home, "plugins", "installed_plugins.json")
      end

      def not_installed
        Entry.finding(CHECK, "no rendered Claude Code hooks file for tellem: #{PLUGIN_KEY} is not in #{installed_list}",
                      "#{rplugin_bin} install tellem", { "installed_plugins" => installed_list })
      end

      def rendered_files
        files = installed_paths.map { |path| { "source" => "installed", "path" => File.join(path, "hooks", "hooks.json") } }
        package = File.join(Tellem.root, "hooks", "hooks.json")
        files << { "source" => "package", "path" => package } if Record::FS.lexists?(package)
        files.uniq { |file| file["path"] }
      end

      def installed_paths
        document = read_json(installed_list)
        return [] unless document.is_a?(Hash) && document["plugins"].is_a?(Hash)

        Array(document["plugins"][PLUGIN_KEY]).filter_map do |install|
          path = install.is_a?(Hash) ? install["installPath"] : nil
          path.is_a?(String) && !path.empty? ? File.expand_path(path) : nil
        end
      end

      def read_json(path)
        stat = Record::FS.lstat(path)
        return nil unless stat&.file? && stat.size <= MAX_BYTES

        JSON.parse(File.read(path))
      rescue SystemCallError, JSON::ParserError
        nil
      end

      def inspect_file(file)
        path = file["path"]
        next_command = file["source"] == "package" ? "#{rplugin_bin} package tellem" : repackage
        document = read_json(path)
        unless document.is_a?(Hash) && document["hooks"].is_a?(Hash)
          return [Entry.finding(CHECK, "#{path} is missing or is not a Claude Code hooks file", next_command, file)]
        end

        problems = CAPTURE.flat_map { |event, arg| problems_for(document["hooks"], event, arg, async: true) }
        problems += SYNCHRONOUS.flat_map { |event, arg| problems_for(document["hooks"], event, arg, async: false) }
        return [Entry.ok(CHECK, "#{path} runs six capture hooks async at #{ASYNC_TIMEOUT_S} s and stop and session_end synchronously", file)] if problems.empty?

        problems.map { |problem| Entry.finding(CHECK, "#{path}: #{problem}", next_command, file) }
      end

      def problems_for(hooks, event, arg, async:)
        handlers = Array(hooks[event]).flat_map { |group| group.is_a?(Hash) ? Array(group["hooks"]) : [] }
        ours = handlers.select { |handler| ours?(handler, arg) }
        return ["no #{event} entry runs #{RUNNER} #{arg}"] if ours.empty?

        timeout = async ? ASYNC_TIMEOUT_S : SYNC_TIMEOUT_S
        ours.flat_map do |handler|
          found = []
          if async && handler["async"] != true
            found << "#{event} runs #{RUNNER} #{arg} without async true"
          elsif !async && handler["async"] == true
            found << "#{event} runs #{RUNNER} #{arg} async, but it must stay synchronous"
          end
          found << "#{event} runs #{RUNNER} #{arg} with timeout #{handler['timeout'].inspect}, expected #{timeout}" unless handler["timeout"] == timeout
          found
        end
      end

      def ours?(handler, arg)
        return false unless handler.is_a?(Hash) && handler["command"].is_a?(String)

        words = handler["command"].split
        index = words.index { |word| word.delete('"').end_with?("/bin/#{RUNNER}") }
        index ? words[index + 1] == arg : false
      end
    end
  end
end
