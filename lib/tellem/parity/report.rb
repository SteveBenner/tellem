# frozen_string_literal: true

require_relative "../ids"
require_relative "../record/fs"
require_relative "../record/reader"
require_relative "../record/scope"
require_relative "../projections/tokens"
require_relative "../reports/text"
require_relative "history"
require_relative "ledger"
require_relative "rollout"
require_relative "turns"

module Tellem
  module Parity
    LAST = { "claude" => 20, "codex" => 5 }.freeze
    PARITY = "parity"
    MISMATCH = "mismatch"
    NO_INCUMBENT = "no_incumbent"
    SUBAGENT = "--subagent-"
    EXCLUDED_TURNS = %w[thinking sidechain tellem_thinking tellem_sidechain].freeze
    NOT_SHADOWED = "no_hook_records"
    PENDING = "pending"
    SESSION_OPEN = "session_open"
    SESSION_END = "session_end"
    STALE_SECONDS = 86_400

    module_function

    def run(scopes, session: nil, since: nil)
      retired = LAST.keys.to_h { |harness| [harness, Ledger.retired_at(harness)] }
      sessions = scopes.reject { |scope| scope["gone"] }.flat_map { |scope| scope_sessions(scope["root"], session, since, retired) }
      sessions.sort_by! { |entry| [entry["last_at"].to_s, entry["session_key"]] }.reverse!
      { "sessions" => sessions, "criteria" => criteria(sessions) }
    end

    def scope_sessions(root, filter, since, retired = {})
      keys = Record::Scope.session_keys(root).select { |key| wanted?(key, filter) }
      return [] if keys.empty?

      history = History.new(root)
      ledger, ledger_problem, duplicates = Record::Scope.kind(root) == "repository" ? Ledger.read(root) : [{}, nil, {}]
      view = Projections::Tokens.rows(root).group_by { |row| row["session_id"] }
      ledger, duplicates = Ledger.routed(root, view.values.flatten(1), ledger, duplicates) if Record::Scope.kind(root) == "repository"
      known = Record::Scope.session_keys(root).map { |key| key.split("-", 2).last } | ledger.keys
      keys.filter_map do |key|
        last_at = last_at(root, key)
        next if since && last_at.to_s < since

        entry(root, key, last_at, [history, known], [ledger, duplicates, retired], view).tap do |item|
          item["tokens"]["problem"] = ledger_problem if ledger_problem
          item["transcripts"]["problem"] = history.problem if history.problem
        end
      end
    end

    def wanted?(key, filter)
      return true if filter.nil? || filter.empty?

      key == filter || key.split("-", 2).last == filter
    end

    def entry(root, key, last_at, specstory, incumbent, view)
      ledger, duplicates, retired = incumbent
      history, known = specstory
      harness, session_id = key.split("-", 2)
      cutoff = (retired || {})[harness]
      transcripts = behind(transcripts(root, key, session_id, history, known), root, key, last_at)
      mine = view[session_id] || []
      theirs = ledger[session_id] || []
      tokens = pending(tokens(mine, theirs, duplicates, cutoff), [mine, theirs, duplicates, cutoff], root, key, last_at)
      rollout = harness == "codex" ? rollout(root, key, last_at, mine) : nil
      parts = [transcripts["verdict"], tokens["verdict"]]
      parts.concat([rollout.dig("transcripts", "verdict"), rollout.dig("tokens", "verdict")]) if rollout
      verdict = if parts.include?(MISMATCH) then MISMATCH
                elsif parts.include?(PENDING) then PENDING
                elsif parts.include?("match") then PARITY
                else NO_INCUMBENT
                end
      { "session_key" => key, "harness" => harness, "scope_root" => root, "last_at" => last_at, "verdict" => verdict,
        "shadowed" => shadowed?(root, key), "transcripts" => transcripts, "tokens" => tokens, "rollout" => rollout }.compact
    end

    def rollout(root, key, last_at, rows)
      name = tellem_names(root, key)[Ids::MAIN_AGENT]
      result = Rollout.compare(root, key, name && read_transcript(root, key, name), rows)
      waiting = %w[transcripts tokens].any? { |part| result[part]["verdict"] == MISMATCH } && rollout_ahead?(result, last_at) &&
                !ended?(root, key) && !stale?(last_at)
      return result unless waiting

      %w[transcripts tokens].each_with_object(result.dup) do |part, out|
        out[part] = result[part].merge("verdict" => PENDING) if result[part]["verdict"] == MISMATCH
      end.merge("pending" => { "reason" => SESSION_OPEN })
    end

    def rollout_ahead?(result, last_at)
      result["modified"].to_s > last_at.to_s
    end

    def pending(tokens, rows, root, key, last_at)
      return tokens unless tokens["verdict"] == MISMATCH

      mine, theirs, duplicates, cutoff = rows
      only = tokens["causes"].find { |cause| cause["cause"] == "tellem_only_rows" }
      return tokens unless only
      return tokens if ended?(root, key) || stale?(last_at)

      logged = theirs.to_h { |row| [row["id"], true] }
      extra = mine.reject { |row| logged[row["id"]] }
      newest_logged = theirs.group_by { |row| row["agent_id"].to_s }.transform_values { |group| group.map { |row| row["timestamp"].to_s }.max }
      return tokens unless extra.size == only["count"] &&
                           extra.all? { |row| row["timestamp"].to_s >= newest_logged[row["agent_id"].to_s].to_s }

      trial = Ledger.compare(mine - extra, theirs, duplicates, cutoff)
      return tokens unless trial["verdict"] == "match"

      newest = extra.max_by { |row| [row["timestamp"].to_s, row["id"].to_s] }
      tokens.merge("verdict" => PENDING, "pending" => { "reason" => SESSION_OPEN, "row" => newest["id"], "rows" => extra.size })
    end

    def behind(transcripts, root, key, last_at)
      return transcripts unless transcripts["verdict"] == MISMATCH
      return transcripts unless transcripts["causes"].all? { |cause| cause["cause"] == Turns::TELLEM_BEHIND }
      return transcripts if ended?(root, key) || stale?(last_at)

      transcripts.merge("verdict" => PENDING, "pending" => { "reason" => SESSION_OPEN })
    end

    def ended?(root, key)
      dir = Record::Scope.raw_dir(root, key)
      Dir.children(dir).any? do |name|
        next false unless name.end_with?(".jsonl")

        found = false
        Record::Reader.each(File.join(dir, name)) { |record| found ||= record["event"] == SESSION_END }
        found
      end
    rescue SystemCallError
      false
    end

    def stale?(last_at)
      cutoff = (Time.now.utc - STALE_SECONDS).strftime("%Y-%m-%dT%H:%M:%SZ")
      last_at.to_s < cutoff
    end

    def shadowed?(root, key)
      dir = Record::Scope.raw_dir(root, key)
      Dir.children(dir).any? do |name|
        stat = Record::FS.lstat(File.join(dir, name))
        name.end_with?(".jsonl") && stat&.file? && stat.size.positive?
      end
    rescue SystemCallError
      false
    end

    def tokens(mine, theirs, duplicates, cutoff = nil)
      return { "verdict" => NO_INCUMBENT, "rows" => { "tellem" => mine.size, "ledger" => 0 }, "causes" => [] } if theirs.empty?

      Ledger.compare(mine, theirs, duplicates, cutoff)
    end

    def transcripts(root, key, session_id, history, known)
      mine = tellem_names(root, key)
      main = history.present? ? history.main_for(session_id, mine["main"]) : nil
      return { "verdict" => NO_INCUMBENT, "agents" => [], "causes" => [] } unless main

      harness = key.split("-", 2).first
      theirs = { "main" => main }.merge(history.subagents_of(main, harness: harness, session_id: session_id, known: known))
      agents = (mine.keys | theirs.keys).sort.map { |agent| agent_parity(root, key, agent, mine[agent], theirs[agent], history) }
      causes = agents.flat_map { |agent| agent["causes"].map { |cause| cause.merge("agent_key" => agent["agent_key"]) } }
      failed = agents.any? { |agent| agent["verdict"] == MISMATCH }
      excluded = EXCLUDED_TURNS.to_h { |kind| [kind, agents.sum { |agent| agent.dig("excluded", kind).to_i }] }
      { "verdict" => failed ? MISMATCH : "match", "agents" => agents.map { |agent| agent.reject { |name, _| name == "causes" } },
        "excluded" => excluded, "causes" => causes, "accepted" => agents.flat_map { |agent| agent["accepted"] || [] } }
    end

    def agent_parity(root, key, agent, mine, theirs, history)
      base = { "agent_key" => agent, "tellem" => mine, "specstory" => theirs }
      unless mine
        return base.merge("verdict" => MISMATCH, "causes" => [{ "cause" => "specstory_only_transcript" }])
      end
      return base.merge("verdict" => "tellem_only", "causes" => [{ "cause" => "tellem_only_transcript" }]) unless theirs

      ours = read_transcript(root, key, mine)
      incumbent = history.read(theirs)
      return base.merge("verdict" => MISMATCH, "causes" => [{ "cause" => "transcript_unreadable" }]) if ours.nil? || incumbent.nil?

      base.merge(Turns.compare(ours, incumbent, subagent: agent != Ids::MAIN_AGENT, harness: key.split("-", 2).first))
    end

    def tellem_names(root, key)
      dir = Record::Scope.transcripts_dir(root, key)
      return {} unless Record::FS.lstat(dir)&.directory?

      Dir.children(dir).select { |name| name.end_with?(".md") && Record::FS.lstat(File.join(dir, name))&.file? }.sort.to_h do |name|
        stem = name.delete_suffix(".md")
        agent = stem.include?(SUBAGENT) ? stem.split(SUBAGENT, 2).last : Ids::MAIN_AGENT
        [agent, name]
      end
    rescue SystemCallError
      {}
    end

    def read_transcript(root, key, name)
      Record::FS.read(File.join(Record::Scope.transcripts_dir(root, key), name))
    rescue SystemCallError, SymlinkRefused
      nil
    end

    def last_at(root, key)
      latest = nil
      Record::Reader.each(Record::Scope.derived_path(root, key)) do |record|
        ts = record["ts"]
        latest = ts if ts.is_a?(String) && (latest.nil? || ts > latest)
      end
      latest
    end

    def criteria(sessions)
      shadowed = sessions.select { |entry| entry["shadowed"] && ![NO_INCUMBENT, PENDING].include?(entry["verdict"]) }
      groups = LAST.to_h do |harness, count|
        chosen = shadowed.select { |entry| entry["harness"] == harness }.first(count)
        passing = chosen.count { |entry| entry["verdict"] == PARITY }
        used = sessions.any? { |entry| entry["shadowed"] && entry["harness"] == harness && entry["verdict"] != NO_INCUMBENT }
        newest_failing = chosen.index { |entry| entry["verdict"] != PARITY }
        needs = newest_failing ? count - newest_failing : count - chosen.size
        [harness, { "required" => count, "considered" => chosen.size, "passing" => passing, "used" => used, "needs" => needs,
                    "met" => !used || (chosen.size == count && passing == chosen.size),
                    "failing" => chosen.reject { |entry| entry["verdict"] == PARITY }.map { |entry| entry["session_key"] } }]
      end
      waiting = pending_sessions(sessions)
      met = waiting.empty? && groups.values.any? { |group| group["used"] } && groups.values.all? { |group| group["met"] }
      groups.merge("met" => met, "not_counted" => not_counted(sessions), "pending" => waiting)
    end

    def pending_sessions(sessions)
      sessions.select { |entry| entry["shadowed"] && entry["verdict"] == PENDING }.map do |entry|
        { "session_key" => entry["session_key"], "harness" => entry["harness"],
          "reason" => entry.dig("tokens", "pending", "reason") || entry.dig("transcripts", "pending", "reason") ||
            entry.dig("rollout", "pending", "reason") }
      end
    end

    def not_counted(sessions)
      sessions.reject { |entry| entry["shadowed"] }.map do |entry|
        { "session_key" => entry["session_key"], "harness" => entry["harness"], "verdict" => entry["verdict"], "reason" => NOT_SHADOWED }
      end
    end

    def text(report)
      rows = report["sessions"].map do |entry|
        rollout = entry["rollout"]
        found = entry["transcripts"]["causes"] + entry["tokens"]["causes"]
        found += rollout["transcripts"]["causes"] + rollout["tokens"]["causes"] if rollout
        causes = found.map { |cause| cause["field"] || cause["counter"] || cause["cause"] }
        [entry["session_key"], entry["verdict"], entry["transcripts"]["verdict"], entry["tokens"]["verdict"],
         rollout ? "#{rollout['transcripts']['verdict']}/#{rollout['tokens']['verdict']}" : "-", Reports::Text.cell(causes.uniq)]
      end
      criteria = report["criteria"]
      summary = LAST.keys.map do |harness|
        group = criteria[harness]
        next "#{harness} has nothing to compare against here (no shadowed session with a reference), not required" unless group["used"]

        needs = group["needs"].to_i.positive? ? "; needs #{group['needs']} more passing sessions" : ""
        "#{harness} #{group['passing']}/#{group['required']} passing of the last #{group['required']} with a reference (incumbent output, or the rollout for Codex)#{needs}"
      end
      excluded = report["sessions"].sum { |entry| entry["tokens"].dig("excluded", "duplicate_ids").to_i }
      synthetic = report["sessions"].sum { |entry| entry["tokens"].dig("excluded", "synthetic_ids").to_i }
      turns = EXCLUDED_TURNS.map { |kind| "#{report['sessions'].sum { |entry| entry['transcripts'].dig('excluded', kind).to_i }} #{kind}" }
      [Reports::Text.table(%w[SESSION VERDICT TRANSCRIPTS TOKENS ROLLOUT CAUSES], rows),
       "excluded from TOKENS comparison: #{excluded} ids the incumbent ledger wrote more than once, " \
       "#{synthetic} zero-counter <synthetic> ledger rows",
       "accepted incumbent differences: #{accepted_text(report['sessions'])}",
       "excluded from transcript comparison: #{turns.join(', ')} turns",
       "cutover criteria #{criteria['met'] ? 'met' : 'unmet'}: #{summary.join('; ')}",
       "pending (session open, and the newest message is not yet in the incumbent ledger or the newest turns not yet " \
       "in tellem's transcript; left out of the counts): #{pending_text(criteria['pending'])}",
       "not counted (imported, no hook records, so no billing or permission_mode): #{left_out(criteria['not_counted'])}"].join("\n")
    end

    def accepted_text(sessions)
      items = sessions.flat_map do |entry|
        rollout = entry["rollout"] || {}
        (entry["tokens"]["accepted"] || []) + (entry["transcripts"]["accepted"] || []) +
          (rollout.dig("tokens", "accepted") || []) + (rollout.dig("transcripts", "accepted") || [])
      end
      counts = items.each_with_object(Hash.new(0)) { |item, out| out[item["reason"]] += item["count"].to_i }
      counts.empty? ? "none" : counts.sort.map { |reason, count| "#{count} #{reason}" }.join(", ")
    end

    def pending_text(entries)
      entries.empty? ? "none" : entries.map { |entry| entry["session_key"] }.join(", ")
    end

    def left_out(entries)
      return "none" if entries.empty?

      entries.map { |entry| "#{entry['session_key']} (#{entry['verdict']})" }.join(", ")
    end
  end
end
