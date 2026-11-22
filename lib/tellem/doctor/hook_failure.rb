# frozen_string_literal: true

require "json"
require_relative "../ports/harness_paths"
require_relative "entry"

module Tellem
  module Doctor
    module HookFailure
      CHECK = "hook_failure"
      FILE = "hook-load-failure.json"
      MAX_BYTES = 4096

      module_function

      def check
        path = File.join(Ports::HarnessPaths.state_dir, FILE)
        return Entry.ok(CHECK, "no hook load failure recorded", { "path" => path }) unless File.file?(path)

        data = JSON.parse(File.read(path, MAX_BYTES))
        detail = data.merge("path" => path)
        Entry.finding(CHECK, "the last hook run failed to load: #{data['error_class']}: #{data['message']} (Ruby #{data['ruby']} at #{data['ruby_path']})",
                      "run a hook again after fixing the cause; the finding clears when a hook run succeeds", detail)
      rescue JSON::ParserError, SystemCallError => e
        Entry.finding(CHECK, "the hook failure file #{path} is unreadable: #{e.class}", "remove #{path}", { "path" => path })
      end
    end
  end
end
