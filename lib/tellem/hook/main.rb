# frozen_string_literal: true

require "json"
require_relative "../version"
require_relative "../errors"
require_relative "../bounds"
require_relative "../ids"
require_relative "../ports/harness_paths"
require_relative "../record/schemas"
require_relative "../record/fs"
require_relative "../record/formats"
require_relative "../record/scope"
require_relative "../record/hook_core"
require_relative "clock"
require_relative "extract"
require_relative "first_start"
require_relative "spawn"

module Tellem
  module Hook
    module Main
      HARNESSES = { "claude-code" => "claude", "claude" => "claude", "codex" => "codex" }.freeze
      CAUSES = {
        "Tellem::InvalidInput" => "malformed_payload",
        "Tellem::InputTooLarge" => "over_bound",
        "Tellem::SymlinkRefused" => "symlink_refused",
        "Tellem::InvalidRecord" => "invalid_record"
      }.freeze

      module_function

      def run(argv, input, plugin_root)
        context = { "tellem_version" => Tellem::VERSION }
        return 0 unless capture_on?(argv, context)

        observe(argv, input, plugin_root, context)
      rescue Exception => e
        failure(e, context || {})
      end

      def capture_on?(argv, context)
        return true if Record::HookCore.capture_enabled?
        return false unless FirstStart.applies?(argv[0].to_s)

        context["event"] = argv[0].to_s
        context["harness"] = argv[1].to_s
        FirstStart.sync
        Record::HookCore.capture_enabled?
      end

      def observe(argv, input, plugin_root, context)
        event = argv[0].to_s
        context["event"] = event
        context["harness"] = argv[1].to_s
        harness = HARNESSES[argv[1].to_s]
        return gap("unknown_harness", context) unless harness
        return gap("unknown_event", context) unless Record::Formats::RAW_EVENTS.include?(event)

        data, over, total = Bounds.read_bounded(input, Bounds::RECORD_BYTES)
        context["payload_bytes"] = total
        return gap("over_limit", context.merge("over_limit" => true)) if over

        payload = Bounds.parse_json(data)
        return gap("payload_not_object", context) unless payload.is_a?(Hash)

        fields = Extract.fields(payload, harness: harness, event: event)
        context["harness_event"] = fields["harness_event"]
        context["missing_keys"] = fields["missing_keys"] unless fields["missing_keys"].empty?
        session_key = Ids.session_key(harness, fields["session_id"])
        return gap("invalid_session_id", context) unless session_key

        context["session_key"] = session_key
        agent_key = Ids.agent_key(fields["agent_id"])
        return gap("invalid_agent_id", context) unless agent_key

        record_observation(fields, session_key, agent_key, total, plugin_root, context)
      end

      def record_observation(fields, session_key, agent_key, total, plugin_root, context)
        cwd = fields["cwd"].to_s
        known = Record::HookCore.read_home(File.join(Ports::HarnessPaths.homes_dir, session_key))
        moved = Record::HookCore.excluded_home?(known)
        root = if moved
                 Record::Scope.user_root
               else
                 known ? known["root"] : Record::Scope.locate(cwd)
               end
        return 0 unless Record::HookCore.capture_enabled?(root)

        inferred = !(fields["event"] == "session_start" && agent_key == Ids::MAIN_AGENT)
        entry = Record::HookCore.home_for(session_key, cwd, inferred: inferred)
        fields = fields.merge("payload_bytes" => total, "over_limit" => false, "tellem_version" => Tellem::VERSION,
                              "hook_ms" => Clock.hook_ms)
        record = Record::Formats.raw(fields, ts_ns: Record::FS.now_ns, pid: Process.pid)
        Record::HookCore.append(Record::HookCore.raw_path(entry, session_key, agent_key), JSON.generate(record))
        gap("home_inferred", context) if known.nil? && entry["inferred"]
        gap("home_moved_excluded", context) if moved
        gap("exclude_roots_unreadable", context) if Record::Exclude.unreadable?
        gap("shape_unrecognized", context) if fields["shape"] == "unrecognized"
        Spawn.deriver(plugin_root, entry["root"]) if Spawn.derive?(fields["harness"], fields["event"], fields["tool"])
        0
      end

      def gap(cause, context)
        Record::HookCore.hook_gap(cause, context)
        0
      end

      def failure(error, context)
        fields = context.merge("error_class" => error.class.name.to_s)
        fields["errno"] = error.errno if error.is_a?(SystemCallError)
        cause = error.is_a?(SystemCallError) ? "system_error" : CAUSES.fetch(error.class.name.to_s, "exception")
        Record::HookCore.hook_gap(cause, fields)
        0
      rescue Exception
        0
      end
    end
  end
end
