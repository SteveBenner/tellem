# frozen_string_literal: true

require "yaml"
require_relative "../errors"
require_relative "../version"
require_relative "../ports/harness_paths"
require_relative "../record/fs"
require_relative "../record/scope"
require_relative "tasks"

module Tellem
  module Config
    KILL_SWITCHES = {
      capture: "TELLEM_DISABLED",
      derive: "TELLEM_DERIVE_DISABLED",
      backend: "TELLEM_BACKEND_DISABLED"
    }.freeze
    KEY_KILLS = {
      "features.capture" => :capture,
      "features.derive" => :derive,
      "features.mirror_sync" => :backend
    }.freeze
    SCOPE_ONLY = %w[visibility].freeze
    USER_ONLY = %w[scope.exclude_roots].freeze
    CUTOVER_ONLY = { "cutover.state" => "cutover", "retention.native" => true, "otel.receiver" => true, "retention.purge" => true }.freeze
    PLAN_ONLY = %w[authority.claude authority.codex].freeze
    STARTUP_FILES = %w[.bashrc .zshrc .profile .bash_profile].freeze
    CUTOVER_PLAN = "tellem cutover plan"
    CUTOVER_ROLLBACK = "tellem cutover rollback"
    CUTOVER_STATE = "cutover.state"
    CUTOVER_SHADOW = "shadow"
    DEFAULT_LAYER = "default"

    module_function

    def settings
      @settings ||= Rplugin::Settings.for(Tellem.root)
    end

    def keys
      settings.keys
    end

    def entry(key)
      settings.entry(key.to_s)
    rescue Rplugin::Refused
      raise UsageError.new("unknown setting #{key}", next_command: "tellem config list")
    end

    def disabled?(switch)
      ENV[KILL_SWITCHES.fetch(switch.to_sym)] == "1"
    end

    def get(key, scope: nil)
      explain(key, scope: scope)[:value]
    end

    def explain(key, scope: nil)
      entry = entry(key)
      kill = KEY_KILLS[entry["key"]]
      return { key: entry["key"], value: false, layer: "kill_switch" } if kill && disabled?(kill)

      if scope
        raw = scope_values(scope)
        if raw.key?(entry["key"])
          value, problem = settings.coerce_file_value(entry, raw[entry["key"]])
          return { key: entry["key"], value: value, layer: "scope" } unless problem
        end
      end
      return { key: entry["key"], value: default_value(entry["key"]), layer: DEFAULT_LAYER } if scope_only?(entry["key"])

      { key: entry["key"], value: settings.get(entry["key"]), layer: settings.layer(entry["key"]) }
    end

    def scope_only?(key)
      SCOPE_ONLY.include?(key)
    end

    def default_value(key)
      settings.explain(key).find { |row| row[:layer] == DEFAULT_LAYER }[:value]
    end

    def ignored_value(key)
      return nil unless scope_only?(key)

      row = settings.explain(key).find { |item| item[:layer] != DEFAULT_LAYER && !item[:value].nil? && item[:problem].nil? }
      row && { "key" => key, "value" => row[:value], "layer" => row[:layer], "source" => row[:source] }
    end

    def require_scope!(key, scope)
      if scope && USER_ONLY.include?(key)
        raise UsageError.new("#{key} is a user-level setting; a per-scope value would be ignored",
                             next_command: "tellem config set #{key} VALUE")
      end
      return unless scope_only?(key)
      return if scope && Record::Scope.kind(scope) == "repository"

      raise UsageError.new("#{key} is declared per repository scope only; a user-level value is ignored",
                           next_command: "tellem config set #{key} VALUE --scope REPOSITORY")
    end

    def refuse_cutover_only!(key, value)
      entry = entry(key)
      if PLAN_ONLY.include?(entry["key"])
        raise UsageError.new("#{entry['key']} is set only by tellem cutover apply and rollback; review it with #{CUTOVER_PLAN}",
                             next_command: CUTOVER_PLAN)
      end
      return unless CUTOVER_ONLY.key?(entry["key"])

      parsed, problem = settings.parse_text(entry, value)
      if entry["key"] == CUTOVER_STATE
        refuse_cutover_state!(parsed)
        return
      end
      return if problem || parsed != CUTOVER_ONLY[entry["key"]]

      raise UsageError.new("#{entry['key']} is switched on only by tellem cutover apply; review it with #{CUTOVER_PLAN}",
                           next_command: CUTOVER_PLAN)
    end

    def refuse_cutover_state!(parsed)
      if parsed == CUTOVER_SHADOW
        raise UsageError.new("#{CUTOVER_STATE} returns to #{CUTOVER_SHADOW} only by #{CUTOVER_ROLLBACK}, which restores ~/.ai with it",
                             next_command: CUTOVER_ROLLBACK)
      end
      return if parsed == "cutover" && no_incumbent?

      raise UsageError.new("#{CUTOVER_STATE} is set only by tellem cutover apply and rollback; review it with #{CUTOVER_PLAN}",
                           next_command: CUTOVER_PLAN)
    end

    def no_incumbent?
      return false if Ports::HarnessPaths.ai_home
      return false if Record::FS.lstat(Ports::HarnessPaths.specstory_home)

      STARTUP_FILES.none? do |name|
        path = File.join(Ports::HarnessPaths.home, name)
        File.file?(path) && File.read(path, 1_048_576).to_s.b.include?("specstory")
      end
    end

    def tasks_rules
      Tasks.rules(settings)
    end

    def tasks_system_prompts
      Tasks.system_prompts(settings)
    end

    def list(scope: nil)
      keys.sort.map { |key| explain(key, scope: scope) }
    end

    def set(key, value, scope: nil)
      entry = entry(key)
      require_scope!(entry["key"], scope)
      Tasks.validate_text!(entry["key"], value) if Tasks.setting?(entry["key"]) && value.is_a?(String)
      if scope
        parsed, problem = settings.parse_text(entry, value)
        raise UsageError.new("#{entry['key']}: #{problem}") if problem

        values = scope_values(scope).merge(entry["key"] => parsed)
        write_scope_values(scope, values)
      else
        begin
          settings.set(entry["key"], value)
        rescue Rplugin::Refused => e
          raise UsageError.new(e.message)
        end
      end
      sync_flag(entry["key"], scope: scope)
      explain(entry["key"], scope: scope)
    end

    def unset(key, scope: nil)
      entry = entry(key)
      require_scope!(entry["key"], scope)
      if scope
        values = scope_values(scope)
        values.delete(entry["key"])
        write_scope_values(scope, values)
      else
        settings.unset(entry["key"])
      end
      sync_flag(entry["key"], scope: scope)
      explain(entry["key"], scope: scope)
    end

    def sync_flag(key, scope: nil)
      case key
      when "features.capture" then sync_capture_flag(scope: scope)
      when "capture.fsync" then sync_fsync_flag
      when "scope.exclude_roots" then sync_exclude_roots
      end
    end

    def scope_values(scope_root)
      path = Record::Scope.config_file(scope_root)
      return {} unless Record::FS.lexists?(path)

      data = YAML.safe_load(Record::FS.read(path), aliases: false)
      data.is_a?(Hash) ? flatten(data) : {}
    rescue Psych::Exception
      {}
    end

    def flatten(hash, prefix = nil)
      hash.each_with_object({}) do |(key, value), out|
        name = prefix ? "#{prefix}.#{key}" : key.to_s
        if value.is_a?(Hash)
          out.merge!(flatten(value, name))
        else
          out[name] = value
        end
      end
    end

    def write_scope_values(scope_root, values)
      Record::Scope.prepare(scope_root)
      body = values.empty? ? "{}\n" : YAML.dump(values.sort.to_h).delete_prefix("---\n")
      Record::FS.replace(Record::Scope.config_file(scope_root), body)
    end

    def sync_capture_flag(scope: nil)
      user_value = mirror_flag(Ports::HarnessPaths.capture_flag, settings.get("features.capture") == true)
      sync_scope_capture(scope) if scope
      sync_exclude_roots
      user_value
    end

    def sync_fsync_flag
      mirror_flag(Ports::HarnessPaths.capture_fsync_flag, settings.get("capture.fsync") == true)
    end

    def sync_exclude_roots
      file = Ports::HarnessPaths.exclude_roots_file
      roots = settings.get("scope.exclude_roots").to_s.split(":").map(&:strip).reject(&:empty?).map { |root| resolved_root(root) }.uniq.sort
      if roots.empty?
        Record::FS.unlink_quiet(file)
      else
        Record::FS.mkdir_p(Ports::HarnessPaths.state_dir)
        Record::FS.replace(file, "#{roots.join("\n")}\n")
      end
      roots
    end

    def resolved_root(root)
      expanded = File.expand_path(root)
      File.realpath(expanded)
    rescue SystemCallError
      expanded
    end

    def mirror_flag(flag, present)
      if present
        Record::FS.mkdir_p(Ports::HarnessPaths.state_dir)
        Record::FS.write_new(flag, "") unless Record::FS.lexists?(flag)
      else
        Record::FS.unlink_quiet(flag)
      end
      present
    end

    def sync_scope_capture(scope_root)
      raw = scope_values(scope_root)
      off = Record::Scope.capture_off(scope_root)
      if raw["features.capture"] == false
        Record::FS.write_new(off, "") unless Record::FS.lexists?(off)
      else
        Record::FS.unlink_quiet(off)
      end
    end
  end
end
