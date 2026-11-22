# frozen_string_literal: true

require_relative "../errors"
require_relative "../ids"
require_relative "../seams"
require_relative "../ports/harness_paths"
require_relative "../record/lock"
require_relative "../record/registry"
require_relative "../backends/events"
require_relative "../deriver/run"
require_relative "candidate"
require_relative "files"
require_relative "native"
require_relative "specstory"
require_relative "ledger"
require_relative "presence"
require_relative "pass"

module Tellem
  module Import
    KINDS = %w[native specstory ledger].freeze
    IMPORT = "import"
    SKIP = "skip"

    module_function

    def plan(sources, paths)
      build(sources, paths).first
    end

    def apply(plan_id, sources, paths)
      current, candidates = build(sources, paths)
      unless plan_id == current["plan_id"]
        raise ConfirmationRequired.new("confirmation id #{plan_id} does not match the current plan #{current['plan_id']}; nothing was imported",
                                       next_command: command(current), detail: current)
      end

      chosen = candidates.select { |candidate| decision(current, candidate)["action"] == IMPORT }
      scopes = chosen.group_by(&:home_root).sort.map { |root, list| apply_scope(root, list) }
      verify(current)
      Backends::Events.emit("tellem.import.applied", { "plan_id" => current["plan_id"], "sources" => current["sources"],
                                                        "sessions_imported" => chosen.size,
                                                        "observations_added" => scopes.sum { |scope| scope["observations_added"] } })
      current.merge("applied" => true, "scopes" => scopes, "sources_unchanged" => true)
    end

    def build(sources, paths)
      kinds = Array(sources).map(&:to_s)
      raise UsageError.new("import needs one of #{KINDS.join(', ')}") if kinds.empty? || !(kinds - KINDS).empty?

      expanded = Array(paths).compact.map { |path| File.expand_path(path) }
      harness = harness_port
      skipped = []
      ledgers = []
      candidates = kinds.flat_map { |kind| collect(kind, expanded, harness, skipped, ledgers) }
      candidates.sort_by! { |candidate| [candidate.session_key, KINDS.index(candidate.source)] }
      presence = Presence.new(harness)
      sessions = candidates.map { |candidate| entry(candidate, presence) }
      files = candidates.flat_map(&:files).uniq.sort.map { |path| Files.entry(path) }
      document = {
        "sources" => kinds, "paths" => expanded, "sessions" => sessions, "files" => files,
        "skipped" => skipped.sort_by { |item| [item["path"], item["cause"]] },
        "ledgers" => ledgers.sort_by { |item| item["path"] },
        "import_sessions" => sessions.count { |item| item["action"] == IMPORT }
      }
      [{ "plan_id" => plan_id(document) }.merge(document), candidates]
    end

    def collect(kind, paths, harness, skipped, ledgers)
      case kind
      when "native" then Native.candidates(paths, harness, skipped)
      when "specstory" then SpecStory.candidates(paths, harness, skipped)
      else Ledger.candidates(paths, skipped, ledgers)
      end
    end

    def entry(candidate, presence)
      present = presence.sources(candidate)
      chosen = present.first
      {
        "session_key" => candidate.session_key, "harness" => candidate.harness, "home_root" => candidate.home_root,
        "source" => candidate.source, "chosen_source" => chosen, "other_sources" => present - [chosen],
        "action" => chosen == candidate.source ? IMPORT : SKIP, "items" => candidate.items, "files" => candidate.files.size
      }
    end

    def decision(plan, candidate)
      plan["sessions"].find { |item| item["session_key"] == candidate.session_key && item["source"] == candidate.source }
    end

    def plan_id(document)
      Ids.sha256(Ids.canonical_json(document))[0, 12]
    end

    def harness_port
      unless defined?(Rplugin::Ports)
        raise CapabilityUnavailable.new("the rplugin SDK is not loaded, so the harness port is unavailable", next_command: "rplugin doctor tellem")
      end

      Rplugin::Ports.for(Ports::HarnessPaths::PLUGIN_ID, root: Tellem.root).harness
    end

    def apply_scope(root, list)
      totals = locked(root) do
        totals = Deriver::Totals.new
        natives = list.select { |candidate| candidate.source == Native::SOURCE }
        Pass.new(root, Deriver::Timer.new(Deriver::PHASES), totals, natives).run unless natives.empty?
        others = list - natives
        unless others.empty?
          context = Deriver::Context.new(root)
          SpecStory.apply(context, others.select { |candidate| candidate.source == SpecStory::SOURCE }, totals)
          Ledger.apply(context, others.select { |candidate| candidate.source == Ledger::SOURCE }, totals)
        end
        totals
      end
      Record::Registry.register(root)
      derive = list.all? { |candidate| candidate.source == Native::SOURCE } ? nil : Seams.fetch(:deriver).run(root, wait: true)
      {
        "root" => root, "sessions" => list.map(&:session_key).uniq.sort, "observations_added" => totals.observations,
        "gaps_added" => totals.gaps.size, "errors" => totals.errors, "derive" => derive && derive.slice("status", "observations_added")
      }
    end

    def locked(root)
      handle = Record::Lock.acquire(root)
      handle = Record::Lock.acquire(root) if handle.nil? && Record::Lock.wait_idle(root, timeout_s: Deriver::WAIT_S)
      raise Busy.new("the deriver holds #{root}; nothing more was imported", next_command: "tellem import --confirm PLAN_ID") unless handle

      begin
        yield
      ensure
        Record::Lock.release(handle)
      end
    end

    def verify(plan)
      changed = plan["files"].reject do |before|
        after = Files.regular?(before["path"]) ? Files.entry(before["path"]) : nil
        after && after["bytes"] == before["bytes"] && after["sha256"] == before["sha256"]
      end
      return if changed.empty?

      raise OperationalFailure.new("#{changed.size} source files changed while they were imported",
                                   next_command: command(plan), detail: { "changed" => changed.map { |item| item["path"] } })
    end

    def command(plan)
      paths = plan["paths"].map { |path| " --path #{path}" }.join
      "tellem import #{plan['sources'].join(',')}#{paths}"
    end

    def text(plan)
      lines = ["import plan #{plan['plan_id']} (#{plan['sources'].join(', ')})"]
      plan["sessions"].each do |item|
        others = item["other_sources"].empty? ? "" : "; also #{item['other_sources'].join(', ')}"
        verb = item["action"] == IMPORT ? "import" : "skip  "
        lines << "  #{verb} #{item['session_key']} from #{item['source']} into #{item['home_root']} " \
                 "(#{item['items']} items, chosen #{item['chosen_source']}#{others})"
      end
      lines << "  nothing to import" if plan["sessions"].empty?
      plan["skipped"].each { |item| lines << "  skipped #{item['path']}: #{item['cause']}#{item['rows'] ? " (#{item['rows']} rows)" : ''}" }
      plan["ledgers"].each do |item|
        lines << "  ledger #{item['path']}: #{item['rows']} rows, #{item['duplicate_ids']} duplicate ids collapsed " \
                 "(#{item['rows_collapsed']} rows dropped, earliest kept)"
      end
      lines << "  #{plan['import_sessions']} of #{plan['sessions'].size} sessions to import; #{plan['files'].size} source files hashed"
      lines.join("\n")
    end

    def applied_text(result)
      lines = [text(result)]
      result["scopes"].each do |scope|
        derive = scope["derive"] ? "; derive #{scope['derive']['status']}" : ""
        lines << "applied to #{scope['root']}: #{scope['sessions'].size} sessions, #{scope['observations_added']} observations, " \
                 "#{scope['gaps_added']} gaps#{derive}"
      end
      lines << "every source file's sha256 is unchanged"
      lines.join("\n")
    end
  end
end
