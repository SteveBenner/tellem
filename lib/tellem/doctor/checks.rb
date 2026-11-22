# frozen_string_literal: true

require "shellwords"
require "yaml"
require_relative "../version"
require_relative "../authority/restore"
require_relative "../authority/state"
require_relative "../authority/switch"
require_relative "../config/resolver"
require_relative "../cutover/apply"
require_relative "../ingest/claude_bodies"
require_relative "../backends/selector"
require_relative "../ports/harness_paths"
require_relative "../record/exclude"
require_relative "../record/fs"
require_relative "../record/registry"
require_relative "../record/scope"
require_relative "../seams"
require_relative "entry"

module Tellem
  module Doctor
    module Checks
      HARNESSES = %w[claude codex].freeze
      FALLBACK_RPLUGIN = "1.19.0"

      module_function

      def capture(scope_root)
        flag = Record::FS.lexists?(Ports::HarnessPaths.capture_flag)
        scope_off = Record::FS.lexists?(Record::Scope.capture_off(scope_root))
        explained = Config.explain("features.capture")
        detail = { "setting" => explained[:value], "layer" => explained[:layer], "flag_file" => flag,
                   "scope_root" => scope_root, "scope_off" => scope_off, "kill_switch" => Config.disabled?(:capture) }
        if detail["kill_switch"]
          Entry.finding("capture", "capture is disabled by TELLEM_DISABLED=1", "unset TELLEM_DISABLED", detail)
        elsif explained[:value] != true
          Entry.finding("capture", "capture is off (features.capture false, #{explained[:layer]} layer)", "tellem config set features.capture true", detail)
        elsif !flag
          Entry.finding("capture", "features.capture is on but #{Ports::HarnessPaths.capture_flag} is missing", "tellem config set features.capture true", detail)
        elsif scope_off
          Entry.finding("capture", "capture is off for the scope #{scope_root}", "tellem config set features.capture true --scope #{scope_root}", detail)
        else
          Entry.ok("capture", "capture is on", detail)
        end
      end

      def harnesses
        unless defined?(Ports::Harness)
          return [Entry.finding("harness_version", "the harness port needs rplugin loaded", "#{rplugin_bin} version", { "harness" => nil })]
        end

        port =Ports::Harness.new(plugin_id: Ports::HarnessPaths::PLUGIN_ID, root: Tellem.root)
        HARNESSES.map do |harness|
          version = port.harness_version(harness)
          if version
            Entry.ok("harness_version", "#{harness} #{version}", { "harness" => harness, "version" => version })
          else
            Entry.finding("harness_version", "#{harness} is not on PATH or did not report a version", "#{harness} --version",
                          { "harness" => harness, "version" => nil })
          end
        end
      end

      def registry
        registry_scopes + excluded(Record::Registry.entries)
      end

      def excluded(entries)
        return [Entry.finding("registry", "scope.exclude_roots cannot be read, so tellem treats every repository as excluded", "tellem config set scope.exclude_roots VALUE", { "file" => Ports::HarnessPaths.exclude_roots_file })] if Record::Exclude.unreadable?

        entries.filter_map do |entry|
          root = entry["root"].to_s
          next if root.empty? || root == Record::Scope.user_root || !Record::Exclude.covers?(root)

          dir = Record::Scope.dir(root)
          next unless Record::FS.lstat(dir)

          Entry.finding("registry", "a .tellem directory sits in the excluded root #{root}; tellem never writes there and removes nothing",
                        "rm -r -- #{Shellwords.escape(dir)}", { "root" => root, "path" => dir, "scope_id" => entry["scope_id"] })
        end
      end

      def registry_scopes
        entries = Record::Registry.resolve
        dangling = entries.select { |entry| entry["gone"] }
        detail = { "registry" => Ports::HarnessPaths.registry_stream, "scopes" => entries.size, "dangling" => dangling.size }
        return [Entry.ok("registry", "#{entries.size} scopes registered, none dangling", detail)] if dangling.empty?

        dangling.map do |entry|
          root = entry["root"].to_s
          info = detail.merge("scope_id" => entry["scope_id"], "root" => root, "root_exists" => File.directory?(root))
          blockers = info["root_exists"] ? derive_blockers(root) : []
          if info["root_exists"] && blockers.empty?
            Entry.finding("registry", "registered scope #{entry['scope_id']} at #{root} is dangling: its .tellem directory is gone",
                          "tellem sync --scope #{root}", info)
          elsif info["root_exists"]
            Entry.finding("registry", "registered scope #{entry['scope_id']} at #{root} is dangling: its .tellem directory is gone; " \
                                      "it comes back at the first sync after derive is on for it, and #{blockers.join(' and ')} " \
                                      "#{blockers.size > 1 ? 'keep' : 'keeps'} derive off", nil, info.merge("blocked_by" => blockers))
          else
            Entry.finding("registry", "registered scope #{entry['scope_id']} at #{root} is dangling: the directory is gone, so reports treat " \
                                      "its sessions as gone; the registry is append-only, so the entry stays", nil, info)
          end
        end
      end

      def derive_blockers(root)
        blockers = []
        blockers << "the TELLEM_DERIVE_DISABLED kill switch" if Config.disabled?(:derive)
        blockers << "the features.derive setting (off)" unless derive_setting(root) == true
        blockers
      end

      def derive_setting(root)
        scoped = Config.scope_values(root)
        scoped.key?("features.derive") ? scoped["features.derive"] : Config.settings.get("features.derive")
      end

      def backend(scope_root)
        adapter = Backends::Selector.new.for(scope_root)
        status = adapter.status.merge(scope_root: scope_root)
        detail = status.transform_keys(&:to_s)
        if status[:disabled] || Config.disabled?(:backend)
          Entry.finding("backend", "the mirror backend is disabled by TELLEM_BACKEND_DISABLED=1", "unset TELLEM_BACKEND_DISABLED", detail)
        elsif adapter.kind == "none"
          Entry.finding("backend", "no mirror backend for #{scope_root}; the files are the only store", "tellem store provision sqlite --scope #{scope_root}", detail)
        elsif status[:provisioned] == false
          Entry.finding("backend", "the #{adapter.kind} mirror is configured but not provisioned", "tellem store provision #{adapter.kind} --scope #{scope_root}", detail)
        elsif !status[:reachable] || status[:breaker].to_s != "closed"
          Entry.finding("backend", "the #{adapter.kind} mirror is unreachable or its breaker is #{status[:breaker]}", "tellem store status --scope #{scope_root}", detail)
        else
          Entry.ok("backend", "#{adapter.kind} mirror reachable, lag #{status[:lag_seconds].nil? ? 'unknown' : "#{status[:lag_seconds]} s"}", detail)
        end
      end

      def persona
        identity = Seams.fetch(:identity)
        unless identity.respond_to?(:status)
          return Entry.finding("persona", "the identity seam has no persona binding; persona evidence answers unknown", "tellem doctor --json",
                               { "seam" => "foundation_default" })
        end

        status = identity.status
        return [Entry.ok("persona", "persona binding is none; persona evidence is not collected", status)] if status["binding"] == "none"

        found = []
        unless status["detected"]
          found << Entry.finding("persona", "persona binding is #{status['binding']} but the persona CLI is not detected on PATH", "#{rplugin_bin} install persona", status)
        end
        found << Entry.finding("persona", "features.persona is off, so persona evidence answers unknown", "tellem config set features.persona true", status) unless status["enabled"]
        found.empty? ? [Entry.ok("persona", "persona bound through #{status['adapter']}", status)] : found
      end

      def authority
        state = Authority::State
        levels = state::HARNESSES.to_h { |name| [name, state.level(name)] }
        stopped = Authority::Switch.reason
        failures = state.restore_failures
        detail = { "levels" => levels, "stop_switch" => stopped, "losses" => state.losses, "restore_failed" => failures.empty? ? nil : failures }.compact
        found = []
        failures.each do |name, item|
          found << Entry.finding("authority", "the #{name} restore failed (#{item['kind']}: #{item['reason']}), so #{name} stays at #{levels[name]} and new sessions may write no native transcript; " \
                                              "#{item['file']}: #{item['error']}; #{Authority::Restore.fix(item)}; every derive retries (#{item['attempts']} so far, first #{item['first_at']})",
                                 Authority::Restore::COMMAND, detail)
        end
        if stopped
          found << Entry.finding("authority", "the authority stop switch is set (#{stopped}); retention, purge, body removal, and SpecStory drift removal are halted",
                                 "tellem authority resume", detail)
        end
        state.losses.each do |item|
          found << Entry.finding("authority", "#{item['kind']} (#{item['reason']}) lowered #{item['harness']} from #{item['from']}; own stays refused until a new plan",
                                 "tellem cutover plan --claude own", detail)
        end
        if levels["claude"] == state::OWN
          reason = Ingest::ClaudeBodies.unsafe_reason(Ports::HarnessPaths.body_spool)
          found << Entry.finding("authority", "the body spool is unsafe at own (#{reason})", "tellem cutover rollback", detail) if reason
        end
        found.concat(specstory_findings(detail))
        return found unless found.empty?

        [Entry.ok("authority", levels.map { |name, level| "#{name} #{level}" }.join(", "), detail)]
      end

      def specstory_findings(detail)
        require_relative "../specstory/prevent"
        info = Specstory::Prevent.status
        Specstory::Prevent.findings(info).map do |message|
          Entry.finding("authority", message, "tellem specstory status", detail.merge("specstory" => info))
        end
      end

      def history_import
        job =Cutover::History.current
        return Entry.ok("history_import", "no subsume history import") unless job

        summary = Cutover::History.text(job).lines.first.chomp
        return Entry.ok("history_import", summary, job) unless Cutover::History::UNFINISHED.include?(job["state"])

        failures = Array(job["failures"]).map { |item| "#{item['source']}#{item['root'] ? " #{item['root']}" : ''}: #{item['error']}" }
        Entry.finding("history_import", ([summary] + failures).join("; ") + "; the subsume stays applied", Cutover::History.resume_command(job["plan_id"]), job)
      end

      def rplugin
        have = defined?(Rplugin::VERSION) ? Rplugin::VERSION.to_s : nil
        need = required_rplugin
        detail = { "rplugin_home" => Ports::HarnessPaths.rplugin_home, "version" => have, "required" => need }
        upgrade = "git -C #{Ports::HarnessPaths.rplugin_home} pull --recurse-submodules && #{rplugin_bin} install tellem"
        if have.nil?
          Entry.finding("rplugin", "rplugin is not loaded from #{detail['rplugin_home']}", upgrade, detail)
        elsif older?(have, need)
          Entry.finding("rplugin", "rplugin #{have} is older than #{need}; async capture hooks and post_tool_failure need it (ADR-13)", upgrade, detail)
        else
          Entry.ok("rplugin", "rplugin #{have} satisfies >= #{need}", detail)
        end
      end

      def required_rplugin
        manifest = YAML.safe_load_file(File.join(Tellem.root, "tellem.rplugin.yml"), aliases: false)
        found = manifest.is_a?(Hash) ? manifest["rplugin"].to_s[/>=\s*(\d+\.\d+\.\d+)/, 1] : nil
        found || FALLBACK_RPLUGIN
      rescue SystemCallError, Psych::Exception
        FALLBACK_RPLUGIN
      end

      def older?(have, need)
        parts = ->(text) { (text.to_s.scan(/\d+/).first(3).map(&:to_i) + [0, 0, 0]).first(3) }
        (parts.call(have) <=> parts.call(need)).negative?
      end

      def rplugin_bin
        File.join(Ports::HarnessPaths.rplugin_home, "bin", "rplugin")
      end
    end
  end
end
