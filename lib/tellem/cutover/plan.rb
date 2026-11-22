# frozen_string_literal: true

require "json"
require_relative "../authority/state"
require_relative "../config/resolver"
require_relative "../discovery"
require_relative "../errors"
require_relative "../ids"
require_relative "../ports/harness_paths"
require_relative "../record/fs"
require_relative "../retention/estimate"
require_relative "builder"
require_relative "callers"
require_relative "discover"
require_relative "dispositions"
require_relative "edits"
require_relative "files"
require_relative "levels"
require_relative "settings"
require_relative "wrappers"

module Tellem
  module Cutover
    SCHEMA = "tellem.cutover/v1"
    PLAN_ID_HEX = 12
    PLAN_ID = /\A[0-9a-f]{12}\z/
    DIRECTIVE = %r{\Adirectives/[^/]+\.md\z}
    AGENTS = /\A(?:.+\/)?AGENTS\.md\z/
    OTEL_SECRET = "otel_token"
    PRIVATE_MODE = 0o600
    NOTHING_FOUND = { "hooks" => [], "registrations" => [], "rules" => [], "callers" => [] }.freeze

    module_function

    def plan(otel: false, request: nil)
      proposal = propose(otel: otel, request: request)
      write_plan(proposal)
      proposal
    end

    def propose(otel: false, request: nil)
      request = Levels.request(request)
      Levels.validate!(request)
      ai_home = Ports::HarnessPaths.ai_home
      if ai_home.nil? && Levels.empty?(request) && !otel
        raise CapabilityUnavailable.new("no ~/.ai directory to plan against", next_command: "set TELLEM_AI_HOME to the ~/.ai checkout, or name a level with --claude or --codex")
      end

      report = Discovery.run(Ports::HarnessPaths.discovery_paths)
      Levels.check!(request, report)
      retire = !ai_home.nil? && (request["specstory"] == "subsume" || Levels.empty?(request))
      found = retire ? Discover.run(ai_home) : NOTHING_FOUND
      build = Builder.new(ai_home)
      hook_names = found["hooks"].map { |hook| hook["name"] }
      found["registrations"].map { |entry| entry["file"] }.uniq.each do |rel|
        build.edit(rel, "registration") { |text| Edits.registrations(text, hook_names) }
      end
      build.edit(Discover::UNREGISTERED, "unregistered", create: true) { |text| Edits.unregistered(text, hook_names) } unless hook_names.empty?
      directives(build, found, hook_names)
      callers(build, found, hook_names)
      extras = {}
      undo = {}
      otel_route = otel ? otel_settings(build, undo) : nil
      extras[otel_route] = ["claude_settings"] if otel_route
      env = level_env(build, request, extras)
      undo.merge!(env["keys"]) if env
      wrappers = request["specstory"] == "subsume" ? Wrappers.plan(build, report) : {}
      extras.merge!(wrappers)
      levels = %w[claude codex].to_h { |name| [name, request[name]] }.compact
      raised = !Levels.raising(request).empty?
      settings = Settings.planned(otel: otel, flip: retire || raised || request["specstory"] == "subsume", retention: retire || raised, levels: levels,
                                  purge: request["purge"], receiver: Levels::WITH_ENV.include?(request["claude"]))
      entries = build.entries
      dispositions = Dispositions.run(build, found, hook_names, extras)
      identity = level_identity(request, report)
      {
        "schema" => SCHEMA,
        "plan_id" => plan_id(build.real_home, otel, entries, settings, dispositions, identity),
        "created_at" => Record::FS.rfc3339,
        "ai_home" => build.real_home,
        "otel" => otel,
        "window_days" => Settings.window_days,
        "settings" => settings,
        "files" => entries,
        "hooks" => found["hooks"],
        "registrations" => found["registrations"],
        "dispositions" => dispositions,
        "request" => request,
        "levels" => levels,
        "discovery_digest" => report["digest"],
        "harness_versions" => report["harnesses"].to_h { |item| [item["id"], item["version"]] },
        "generation" => Authority::State.generation,
        "env" => env,
        "env_undo" => undo,
        "parity_gate" => parity_gate(hook_names, wrappers),
        "readers" => reader_rows(request, report),
        "accepted_parity" => accepted_parity(request, report),
        "freed" => raised ? Retention::Estimate.run(Levels.raising(request)) : nil,
        "notes" => notes(request, report, wrappers)
      }.compact
    end

    def level_identity(request, report)
      [report["digest"], request, Authority::State.generation, Levels.claude_version(report),
       Levels.raising(request).empty? ? nil : Settings.window_days]
    end

    def plan_id(ai_home, otel, entries, settings, dispositions, identity = nil)
      fields = [SCHEMA, ai_home, otel, entries.map { |file| [file["path"], file["before_sha256"], file["after_sha256"]] },
                settings.map { |item| [item["key"], item["value"]] },
                dispositions.map { |item| [item["file"], item["disposition"], item["reason"]] }, identity]
      Ids.sha256(Ids.canonical_json(fields))[0, PLAN_ID_HEX]
    end

    def parity_gate(hook_names, wrappers)
      return "required" unless hook_names.empty?

      wrappers.empty? ? nil : "when_compared"
    end

    def reader_rows(request, report)
      accepted = request["accept_readers"]
      Levels.required_readers(request, report).map do |reader|
        { "id" => reader["id"], "kind" => reader["kind"], "confidence" => reader["confidence"], "accepted" => accepted.include?(reader["id"]) }
      end
    end

    def accepted_parity(request, report)
      request["accept_parity"].map do |name|
        { "name" => name, "version" => Levels.claude_version(report), "loses" => Levels::LOSES.fetch(name) }
      end
    end

    def notes(request, report, wrappers)
      found = []
      found << "open shells and running specstory run processes keep the old behavior until they exit" unless wrappers.empty?
      if request["specstory"] == "subsume"
        found << "D-25 subsume imports history: apply starts a background import of native transcripts, then .specstory/history and TOKENS.jsonl in every registered scope, " \
                 "changing no source; tellem cutover status shows it; a failed import does not undo the subsume; rollback leaves imported records"
      end
      if Levels::WITH_ENV.include?(request["claude"])
        found << "sessions already running keep the environment they started with"
        found << "reasoning text is unavailable at own; entries and discovery say so" if request["claude"] == "own"
      end
      unknown = report["readers"].select { |reader| reader["confidence"] == "unknown" }
      found << "reader scans exceeded a bound: #{unknown.map { |reader| "#{reader['id']} (#{reader['reason']})" }.join(', ')}" unless unknown.empty?
      found << "a Codex plan does not change history.persistence; set it only after checking what it does to rollouts on this host" if request["codex"] == "spool"
      found
    end

    def level_env(build, request, extras)
      level = request["claude"]
      return nil unless Levels::WITH_ENV.include?(level)

      path = File.join(Ports::HarnessPaths.claude_home, "settings.json")
      unless File.directory?(File.dirname(path))
        Levels.refuse("claude_home_missing", "no Claude home at #{File.dirname(path)}, so there is no settings file for this plan to change",
                      next_command: "run claude once, or set CLAUDE_CONFIG_DIR, then tellem cutover plan")
      end

      real = File.join(File.realpath(File.dirname(path)), File.basename(path))
      wanted = Levels.env(level, Edits.otel_env(Settings.otel_port, otel_token), Ports::HarnessPaths.body_spool)
      added = []
      build.edit(path, "claude_settings", create: true, outside: real, create_mode: PRIVATE_MODE) do |text|
        conflicts = Edits.env_conflicts(text, wanted)
        unless conflicts.empty?
          Levels.refuse("env_set_outside", "Claude settings env set outside tellem holds other values for #{conflicts.join(', ')}; tellem never overwrites them",
                        next_command: "remove those keys from #{path}, then tellem cutover plan", detail: { "keys" => conflicts, "path" => path })
        end
        added = Edits.env_added(text, wanted)
        Edits.claude_env(text, wanted)
      end
      extras[path] = ["claude_settings"]
      { "settings_path" => path, "keys" => Edits.env_digests(wanted, added), "spool" => Ports::HarnessPaths.body_spool }
    end

    def directives(build, found, hook_names)
      rule_files = found["rules"].map { |item| item["file"] }.uniq
      hook_names.map { |name| Edits.stem(name) }.each do |stem|
        old_rule = nil
        rule_files.grep(DIRECTIVE).each do |rel|
          build.edit(rel, "rule") do |text|
            updated, changes, rule = Edits.directive(text, stem)
            old_rule ||= rule
            [updated, changes]
          end
        end
        next unless old_rule

        rule_files.grep(AGENTS).each do |rel|
          build.edit(rel, "rule") { |text| Edits.agents_rows(text, stem, old_rule) }
        end
      end
    end

    def callers(build, found, hook_names)
      found["callers"].map { |item| item["file"] }.uniq.select { |rel| Callers.python?(rel) }.each do |rel|
        build.edit(rel, "caller") { |text| Callers.edit(text, hook_names) }
      end
    end

    def otel_settings(build, undo = {})
      path = File.join(Ports::HarnessPaths.claude_home, "settings.json")
      unless Record::FS.lstat(path)&.file?
        raise CapabilityUnavailable.new("no Claude settings file at #{path}", next_command: "create #{path} or set CLAUDE_CONFIG_DIR")
      end

      real = File.join(File.realpath(File.dirname(path)), File.basename(path))
      env = Edits.otel_env(Settings.otel_port, otel_token)
      build.edit(path, "claude_settings", outside: real) do |text|
        undo.merge!(Edits.env_digests(env, Edits.env_added(text, env)))
        Edits.claude_env(text, env)
      end
      path
    end

    def otel_token
      token = Rplugin::Ports.for(Ports::HarnessPaths::PLUGIN_ID, root: Tellem.root).secrets.get(OTEL_SECRET).to_s
      raise Rplugin::MissingSecret, "empty #{OTEL_SECRET}" if token.empty?

      token
    rescue Rplugin::MissingSecret, Rplugin::Refused => e
      raise CapabilityUnavailable.new("the OTLP receiver token #{OTEL_SECRET} is not available: #{e.message}",
                                      next_command: "store a random token as the SDK secret #{OTEL_SECRET}, then tellem cutover plan --otel")
    end

    def dir(plan_id)
      unless PLAN_ID.match?(plan_id.to_s)
        raise OperationalFailure.new("invalid cutover plan id #{plan_id}", next_command: "tellem cutover plan", detail: { "cause" => "invalid_plan_id" })
      end

      File.join(Ports::HarnessPaths.cutover_dir, plan_id)
    end

    def write_plan(proposal)
      target = dir(proposal["plan_id"])
      Record::FS.mkdir_p(target)
      forward = +""
      backward = +""
      proposal["files"].each do |file|
        label = file["inside_ai_home"] ? file["rel"] : file["path"].delete_prefix("/")
        forward << Files.diff(target, label, file["before"], file["after"])
        backward << Files.diff(target, label, file["after"], file["before"])
      end
      Record::FS.replace(File.join(target, "apply.patch"), forward)
      Record::FS.replace(File.join(target, "rollback.patch"), backward)
      Record::FS.replace(File.join(target, "plan.json"), [JSON.pretty_generate(public(proposal)), "\n"].join)
      target
    end

    def public(proposal)
      proposal.merge("files" => proposal["files"].map { |file| file.reject { |key, _| %w[before after].include?(key) } })
    end

    def load(plan_id)
      path = File.join(dir(plan_id), "plan.json")
      JSON.parse(Record::FS.read(path))
    rescue Errno::ENOENT, Errno::ENOTDIR
      raise OperationalFailure.new("no cutover plan #{plan_id}", next_command: "tellem cutover plan", detail: { "cause" => "unknown_plan" })
    rescue JSON::ParserError
      raise OperationalFailure.new("cutover plan #{plan_id} is unreadable", next_command: "tellem cutover plan")
    end

    def latest
      root = Ports::HarnessPaths.cutover_dir
      ids = Dir.children(root).select { |name| PLAN_ID.match?(name) && Record::FS.lexists?(File.join(root, name, "plan.json")) }
      ids.map { |id| load(id) }.max_by { |plan| [plan["created_at"].to_s, plan["plan_id"]] }
    rescue SystemCallError
      nil
    end

    def text(plan)
      lines = ["cutover plan #{plan['plan_id']} against #{plan['ai_home'] || 'this host (no ~/.ai)'}#{plan['otel'] ? ' with OpenTelemetry' : ''}"]
      plan["files"].each do |file|
        routes = file["routes"].to_a.size > 1 ? " (reached through #{file['routes'].join(' and ')})" : ""
        lines << "  #{file['action']} #{file['inside_ai_home'] ? file['rel'] : file['path']}#{routes}: #{file['changes'].join('; ')}"
      end
      plan["settings"].each { |item| lines << "  set #{item['key']} #{item['value']}" }
      lines << "  retention window #{plan['window_days']} days"
      lines.concat(Levels.text(plan))
      lines << "  discovered files:"
      plan["dispositions"].each do |item|
        detail = item["disposition"] == Dispositions::EDIT ? "edit" : "#{item['disposition']}: #{item['reason']}"
        detail += "; lines #{item['remaining']['lines'].join(', ')} kept: #{item['remaining']['reason']}" if item["remaining"]
        lines << "    #{item['file']} [#{item['found_as'].join(', ')}] #{detail}"
      end
      lines << "  patches: #{dir(plan['plan_id'])}/apply.patch and rollback.patch"
      lines.join("\n")
    end

    def unresolved(plan)
      Array(plan["dispositions"]).select { |item| item["disposition"] == Dispositions::UNRESOLVED }
    end
  end
end
