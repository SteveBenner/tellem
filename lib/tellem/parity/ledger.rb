# frozen_string_literal: true

require "json"
require_relative "../errors"
require_relative "../record/fs"
require_relative "../record/reader"
require_relative "../projections/tokens"
require_relative "../ports/harness_paths"

module Tellem
  module Parity
    module Ledger
      FILE = "TOKENS.jsonl"
      GIT = ".git"
      GITDIR_PREFIX = "gitdir: "
      MAX_TARGETS = 64
      COUNTERS = %w[
        input_tokens output_tokens cache_creation_input_tokens cache_read_input_tokens total_tokens reasoning_output_tokens
      ].freeze
      ALWAYS_EXCLUDED = %w[billing_plan stop_hook_active].freeze
      SESSION_END_MODE = ""
      SAMPLE = 3
      SYNTHETIC_MODEL = "<synthetic>"
      UNKNOWN_BILLING = "unknown"
      MODE_CHANGED = "mode_changed_mid_session"
      BILLING_UNDETECTED = "incumbent_billing_undetected"
      CWD_MISSING = "incumbent_cwd_missing"
      RETIRED = "incumbent_retired"
      TOKENS_CAPTURE = "tokens_ledger"
      APPLIED = "applied"
      ZERO_COUNTERS = (COUNTERS | Projections::Tokens::INTEGER_FIELDS).freeze

      module_function

      def retired_at(harness)
        root = Ports::HarnessPaths.cutover_dir
        Dir.children(root).filter_map { |name| retirement(File.join(root, name), harness) }.min
      rescue SystemCallError
        nil
      end

      def retirement(dir, harness)
        state = JSON.parse(Record::FS.read(File.join(dir, "state.json")))
        return nil unless state.is_a?(Hash) && state["direction"] == APPLIED && state["at"].is_a?(String)

        plan = JSON.parse(Record::FS.read(File.join(dir, "plan.json")))
        return nil unless plan.is_a?(Hash)

        hooks = Array(plan["hooks"]).select { |hook| hook.is_a?(Hash) && Array(hook["captures"]).include?(TOKENS_CAPTURE) }.map { |hook| hook["name"] }
        retired = Array(plan["registrations"]).any? do |entry|
          entry.is_a?(Hash) && hooks.include?(entry["hook"]) && entry["file"].to_s.split("/").first == harness
        end
        retired ? state["at"] : nil
      rescue SystemCallError, SymlinkRefused, JSON::ParserError
        nil
      end

      def path(root)
        File.join(root, FILE)
      end

      def read(root)
        file = path(root)
        stat = Record::FS.lstat(file)
        return [{}, nil, {}] unless stat
        return [{}, "ledger_symlink_refused", {}] if stat.symlink?
        return [{}, "ledger_not_a_file", {}] unless stat.file?

        by_session = Hash.new { |hash, key| hash[key] = [] }
        written = Hash.new(0)
        Record::Reader.each(file) do |row|
          next unless row["session_id"].is_a?(String) && row["id"].is_a?(String)

          by_session[row["session_id"]] << row
          written[row["id"]] += 1
        end
        [by_session, nil, written.select { |_id, count| count > 1 }]
      rescue SymlinkRefused
        [{}, "ledger_symlink_refused", {}]
      end

      def routed(root, rows, ledger, duplicates)
        targets = rows.filter_map { |row| target(row["cwd"], root) }.uniq.reject { |dir| same?(dir, root) }.first(MAX_TARGETS)
        targets.each do |dir|
          extra, problem, repeated = read(dir)
          next if problem

          extra.each { |session_id, list| ledger[session_id] = (ledger.key?(session_id) ? ledger[session_id] : []) + list }
          duplicates = duplicates.merge(repeated)
        end
        [ledger, duplicates]
      end

      def target(cwd, boundary)
        return nil unless cwd.is_a?(String) && cwd.start_with?("/")

        dir = cwd.chomp("/")
        until dir.empty?
          git = File.join(dir, GIT)
          main = File.file?(git) ? main_checkout(dir) : nil
          return (same?(main, boundary) || !ledger_dir_ok?(main) ? boundary : main) if main
          return boundary if same?(dir, boundary)
          return (ledger_dir_ok?(dir) ? dir : boundary) if File.exist?(git)

          dir = dir.rpartition("/").first
        end
        boundary
      end

      def main_checkout(dir)
        line = File.open(File.join(dir, GIT), &:gets).to_s.chomp
        return nil unless line.start_with?(GITDIR_PREFIX) && line.include?("/worktrees/")

        gitdir = line.delete_prefix(GITDIR_PREFIX)
        gitdir = File.join(dir, gitdir) unless gitdir.start_with?("/")
        relative = File.open(File.join(gitdir, "commondir"), &:gets).to_s.chomp
        common = File.realpath(File.join(gitdir, relative))
        return nil unless File.basename(common) == GIT

        main = File.dirname(common)
        File.directory?(main) ? main : nil
      rescue SystemCallError
        nil
      end

      def ledger_dir_ok?(dir)
        return false unless File.directory?(dir) && File.writable?(dir)

        file = File.join(dir, FILE)
        !File.exist?(file) || (File.file?(file) && File.writable?(file))
      end

      def same?(one, other)
        File.identical?(one, other)
      end

      def compare(tellem_rows, ledger_rows, duplicates = {}, retired = nil)
        mine = unique(tellem_rows)
        theirs = unique(ledger_rows)
        excluded = (mine.keys | theirs.keys).select { |id| duplicates.key?(id) }
        synthetic = theirs.keys.select { |id| !duplicates.key?(id) && synthetic?(theirs[id]) }
        unwritable = (mine.keys - theirs.keys).select { |id| missing_directory?(mine[id]["cwd"]) }
        after = retired ? (mine.keys - theirs.keys - unwritable).select { |id| mine[id]["timestamp"].to_s >= retired } : []
        (excluded + synthetic + unwritable + after).each do |id|
          mine.delete(id)
          theirs.delete(id)
        end
        causes = []
        only(causes, "ledger_only_rows", theirs.keys - mine.keys)
        only(causes, "tellem_only_rows", mine.keys - theirs.keys)
        field_causes, accepted = fields(mine, theirs)
        causes.concat(field_causes)
        accepted.unshift(accepted_rows(RETIRED, after)) unless after.empty?
        accepted.unshift(accepted_rows(CWD_MISSING, unwritable)) unless unwritable.empty?
        sums = sums(mine.values, theirs.values)
        sums.each do |counter, pair|
          next if pair["tellem"] == pair["ledger"]

          causes << { "cause" => "counter_sum_differs", "counter" => counter }.merge(pair)
        end
        { "verdict" => causes.empty? ? "match" : "mismatch", "rows" => { "tellem" => mine.size, "ledger" => theirs.size },
          "excluded" => { "duplicate_ids" => excluded.size, "ledger_rows" => ledger_rows.count { |row| excluded.include?(row["id"]) },
                          "synthetic_ids" => synthetic.size, "unwritable_cwd_ids" => unwritable.size, "retired_ids" => after.size },
          "sums" => sums, "causes" => causes, "accepted" => accepted }
      end

      def missing_directory?(cwd)
        cwd.is_a?(String) && cwd.start_with?("/") && !File.directory?(cwd)
      end

      def accepted_rows(reason, ids)
        { "reason" => reason, "count" => ids.size, "sample" => ids.sort.first(SAMPLE) }
      end

      def synthetic?(row)
        row["model"] == SYNTHETIC_MODEL && ZERO_COUNTERS.all? { |counter| row[counter].is_a?(Integer) && row[counter].zero? }
      end

      def unique(rows)
        rows.each_with_object({}) { |row, out| out[row["id"]] ||= row if row["id"].is_a?(String) }
      end

      def only(causes, cause, ids)
        return if ids.empty?

        causes << { "cause" => cause, "count" => ids.size, "sample" => ids.sort.first(SAMPLE) }
      end

      def fields(mine, theirs)
        counts = Hash.new { |hash, field| hash[field] = { "count" => 0 } }
        accepted = Hash.new { |hash, reason| hash[reason] = { "count" => 0 } }
        changing = mine.values.map { |row| row["permission_mode"] }.uniq.size > 1
        (mine.keys & theirs.keys).sort.each do |id|
          ours = mine[id]
          incumbent = theirs[id]
          compared(incumbent).each do |field|
            next if ours[field] == incumbent[field]

            reason = accepted_reason(field, ours, incumbent, changing)
            entry = reason ? accepted[reason] : counts[field]
            entry["count"] += 1
            entry["sample"] ||= { "id" => id, "tellem" => ours[field], "ledger" => incumbent[field] }
          end
        end
        [counts.sort.map { |field, entry| { "cause" => "field_differs", "field" => field }.merge(entry) },
         accepted.sort.map { |reason, entry| { "reason" => reason }.merge(entry) }]
      end

      def accepted_reason(field, ours, incumbent, changing)
        return MODE_CHANGED if field == "permission_mode" && changing
        return BILLING_UNDETECTED if field == "billing" && incumbent["billing"] == UNKNOWN_BILLING && ours["billing"] != UNKNOWN_BILLING

        nil
      end

      def compared(incumbent)
        skipped = ALWAYS_EXCLUDED.dup
        skipped << "permission_mode" if incumbent["permission_mode"] == SESSION_END_MODE
        skipped << "billing" if incumbent["provider"] == "codex"
        (Projections::Tokens::FIELDS | incumbent.keys) - skipped
      end

      def sums(mine, theirs)
        COUNTERS.to_h do |counter|
          [counter, { "tellem" => total(mine, counter), "ledger" => total(theirs, counter) }]
        end
      end

      def total(rows, counter)
        rows.sum { |row| row[counter].is_a?(Integer) ? row[counter] : 0 }
      end
    end
  end
end
