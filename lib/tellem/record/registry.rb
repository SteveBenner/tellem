# frozen_string_literal: true

require "json"
require_relative "../version"
require_relative "../ports/harness_paths"
require_relative "exclude"
require_relative "formats"
require_relative "fs"
require_relative "hook_core"
require_relative "reader"
require_relative "scope"

module Tellem
  module Record
    module Registry
      STREAM = "registry"

      module_function

      def register(scope_root, kind: nil)
        return false if scope_root != Scope.user_root && Exclude.covers?(scope_root)

        descriptor = Scope.open(scope_root)
        return false if entries.any? { |entry| entry["scope_id"] == descriptor["scope_id"] }

        entry = Formats.registry_entry(
          scope_id: descriptor["scope_id"],
          root: descriptor["root"],
          kind: kind || descriptor["kind"],
          first_seen: FS.rfc3339
        )
        append(entry)
        true
      end

      def entries
        seen = {}
        read.each do |entry|
          next unless entry.is_a?(Hash) && entry["scope_id"].is_a?(String)

          seen[entry["scope_id"]] ||= entry
        end
        seen.values
      end

      def resolve
        entries.map { |entry| entry.merge("gone" => !File.file?(File.join(Scope.dir(entry["root"].to_s), "scope.json"))) }
      end

      def append(entry)
        if Ports::HarnessPaths.isolated_state?
          HookCore.append(Ports::HarnessPaths.registry_stream, JSON.generate(entry))
        else
          state_port.append(STREAM, entry)
        end
      end

      def read
        if Ports::HarnessPaths.isolated_state?
          Reader.records(Ports::HarnessPaths.registry_stream).first
        else
          state_port.read(STREAM)
        end
      end

      def state_port
        @state_port ||= Rplugin::Ports.for(Ports::HarnessPaths::PLUGIN_ID, root: Tellem.root).state
      end
    end
  end
end
