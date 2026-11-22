# frozen_string_literal: true

require_relative "text"
require_relative "totals"
require_relative "../redact"

module Tellem
  module Tasks
    module Markers
      USAGE = "Usage: /task [status | new [name] | done | split | merge | resume [id or name]]"
      SAFE_ID = /\A[A-Za-z0-9_-]{1,128}\z/
      SCAN_LIMIT = 200
      VERBS = {
        "status" => :verb_status,
        "new" => :verb_new,
        "done" => :verb_done,
        "split" => :verb_split,
        "merge" => :verb_merge,
        "resume" => :verb_resume
      }.freeze

      private

      def match_marker(prompt)
        pattern = /\A[[:space:]\x1c-\x1f]*#{Regexp.escape(@rules['marker'])}(?:[[:space:]\x1c-\x1f]+([\p{L}\p{N}_]+))?(?:[[:space:]\x1c-\x1f]+(.*?))?[[:space:]\x1c-\x1f]*\z/m
        match = pattern.match(prompt)
        return nil unless match

        [(match[1] || "status").downcase, (match[2] || "").then { |value| Text.rstrip(Text.lstrip(value)) }]
      end

      def run_marker(ev, verb, args, now)
        sid = ev["session_id"]
        record = load_session(sid, now)
        repo = repo_of(ev)
        cur, = current(record, now)
        before = record["task_id"]
        fields = {}
        args = Redact.text(args)
        handler = VERBS[verb]
        text = handler.nil? ? USAGE : send(handler, record, sid, repo, cur, args, now, fields)
        fault = @faults[sid]
        text = "Task clock error: #{fault['error']} (#{fault['count']}× since #{fault['first_ts']})\n#{text}" if fault && fault["active"]
        save_session(record, now)
        @log << { "ts" => iso(now), "event" => "marker", "verb" => verb, "args" => args, "session_id" => sid, "task_from" => before, "task_to" => record["task_id"] }.merge(fields)
        text
      end

      def verb_status(_record, _sid, _repo, cur, _args, now, _fields)
        return "No current task." if cur.nil?

        "Current task:\n#{Totals.task_line(cur, now, @rules)}"
      end

      def verb_new(record, sid, repo, _cur, args, now, _fields)
        left = release(record, sid, "new_task", now)
        task = create(repo, sid, now, args.empty? ? nil : args, "marker_new", nil)
        save_task(task, now)
        record["prev_task_id"] = left if left
        record["task_id"] = task["id"]
        record["pin_next"] = true
        record["pending_new"] = false
        "Started a new task.\n#{Totals.task_line(task, now, @rules)}"
      end

      def verb_done(record, _sid, _repo, cur, _args, now, _fields)
        return "No current task." if cur.nil?

        cur["turns"].each do |turn|
          turn["spans"].each { |span| span[1] = [span[0], cur["last_activity"]].max if span[1].nil? }
        end
        cur["attached"] = []
        cur["closed"] = { "at" => cur["last_activity"], "reason" => "done" }
        log_close(cur, now)
        save_task(cur, now)
        record["task_id"] = nil
        record["pending_new"] = true
        "Task closed.\n#{Totals.task_line(cur, now, @rules)}"
      end

      def verb_split(record, sid, _repo, cur, _args, now, fields)
        return "No current task." if cur.nil?

        last = last_turn(cur, sid)
        return "Nothing to split." if last.nil? || cur["turns"].first.equal?(last)

        moved = cur["turns"].select { |turn| turn["session_id"] == sid && turn["at"] >= last["at"] }
        moved_agents = cur["subagents"].select { |agent| agent["session_id"] == sid && agent["start"] >= last["at"] }
        cur["turns"] = cur["turns"].reject { |turn| moved.any? { |item| item.equal?(turn) } }
        cur["subagents"] = cur["subagents"].reject { |agent| moved_agents.any? { |item| item.equal?(agent) } }
        name = last["head"][0, Text::NAME_CHARS]
        task = create(cur["repo"], sid, now, name.empty? ? "pasted content" : name, "split", last["decision"], started: last["at"])
        task["turns"] = moved
        task["subagents"] = moved_agents
        task["wip_counts"] = cur["wip_counts"].dup
        moved.each do |turn|
          words = Text.tokens(turn["head"])
          task["first_tokens"] = words.dup if task["first_tokens"].empty?
          add_fingerprint(task, words)
        end
        recompute_activity(task)
        recompute_activity(cur)
        leave(cur, sid, "split", now)
        save_task(task, now)
        record["prev_task_id"] = cur["id"]
        record["task_id"] = task["id"]
        fields.update("label" => "should_be_new", "decision" => last["decision"])
        "Split the last turn into a new task.\n#{Totals.task_line(task, now, @rules)}"
      end

      def stable_sort(items)
        items.each_with_index.sort_by { |item, index| [yield(item), index] }.map(&:first)
      end

      def verb_merge(record, _sid, _repo, cur, _args, now, fields)
        target_id = record["prev_task_id"]
        return "Nothing to merge into." if cur.nil? || !target_id || target_id == cur["id"]

        target = @tasks[target_id]
        return "Nothing to merge into." if target.nil? || target["merged_into"]

        target["turns"] = stable_sort(target["turns"] + Text.deep_copy(cur["turns"])) { |turn| turn["at"] }
        target["subagents"] = stable_sort(target["subagents"] + Text.deep_copy(cur["subagents"])) { |agent| agent["start"] }
        add_fingerprint(target, cur["fingerprint"])
        %w[sessions attached].each do |key|
          cur[key].each { |item| target[key] << item unless target[key].include?(item) }
        end
        target["last_activity"] = [target["last_activity"], cur["last_activity"]].max
        target["closed"] = nil
        decision = cur["opened_by"]["decision"]
        cur["merged_into"] = target["id"]
        cur["closed"] = { "at" => now, "reason" => "merge" }
        cur["attached"] = []
        log_close(cur, now)
        save_task(cur, now)
        save_task(target, now)
        record["task_id"] = target["id"]
        record["prev_task_id"] = nil
        fields.update("label" => "should_continue", "decision" => decision)
        "Merged into the previous task.\n#{Totals.task_line(target, now, @rules)}"
      end

      def find_resume(args, repo, cur)
        cur_id = cur && cur["id"]
        if !args.empty? && SAFE_ID.match?(args)
          found = @tasks[args]
          return found if found && !found["merged_into"]
        end
        wanted = args.downcase
        stable_sort(@recent) { |item| -item["last_activity"] }.each do |item|
          next if item["id"] == cur_id || (args.empty? && item["repo"] != repo)

          found = @tasks[item["id"]]
          return found if found && !found["merged_into"] && (args.empty? || Text.str(found["name"]).downcase.start_with?(wanted))
        end
        scan.each do |found|
          next if found["id"] == cur_id || found["merged_into"]
          return found if !args.empty? && Text.str(found["name"]).downcase.start_with?(wanted)
          return found if args.empty? && found["repo"] == repo
        end
        nil
      end

      def scan
        @touch.each_with_index.sort_by { |(_id, seq), index| [-seq, index] }.first(SCAN_LIMIT).map { |(id, _seq), _index| @tasks[id] }
      end

      def verb_resume(record, sid, repo, cur, args, now, _fields)
        target = find_resume(args, repo, cur)
        return "No task to resume." if target.nil?

        left = nil
        left = release(record, sid, "resume", now) if cur && cur["id"] != target["id"]
        target = @tasks[target["id"]]
        target["closed"] = nil
        target["last_activity"] = now
        attach(target, sid)
        save_task(target, now)
        record["prev_task_id"] = left if left
        record["task_id"] = target["id"]
        record["pin_next"] = true
        record["pending_new"] = false
        "Resumed task.\n#{Totals.task_line(target, now, @rules)}"
      end
    end
  end
end
