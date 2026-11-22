# frozen_string_literal: true

require "digest"
require_relative "../errors"
require_relative "../redact"
require_relative "text"
require_relative "scoring"
require_relative "totals"
require_relative "markers"

module Tellem
  module Tasks
    class Engine
      include Markers

      EVENT_TYPES = %w[prompt system_prompt tool stop subagent_start subagent_stop session_start session_end].freeze
      RECENT_SECONDS = 86_400
      RECENT_DRIFT = 60
      FINGERPRINT_CAP = 600
      FAULT_DETAIL_CHARS = 300

      attr_reader :rules, :log

      def initialize(rules:, system_prompts:, reader: nil)
        @rules = rules
        @prefixes = system_prompts.dup.freeze
        @reader = reader
        @tasks = {}
        @order = []
        @touch = {}
        @sessions = {}
        @recent = []
        @faults = {}
        @log = []
        @minted = Hash.new(0)
        @seq = 0
      end

      def feed(event)
        ev = Text.stringify(event)
        raise InvalidInput.new("task event needs a numeric time") unless ev["time"].is_a?(Numeric)
        kind = ev["type"].to_s
        raise InvalidInput.new("unknown task event type #{kind.inspect}") unless EVENT_TYPES.include?(kind)
        raise InvalidInput.new("task event needs a session_id") unless ev["session_id"].is_a?(String) && !ev["session_id"].empty?

        now = ev["time"].to_f
        case kind
        when "prompt" then prompt_event(ev, now)
        when "system_prompt" then system_prompt(ev, now)
        when "tool" then tool(ev, now)
        when "stop" then stop(ev, now)
        when "subagent_start" then subagent_start(ev, now)
        when "subagent_stop" then subagent_stop(ev, now)
        when "session_start" then session_start(ev, now)
        when "session_end" then session_end(ev, now)
        end
      end

      def tasks
        @order.map { |id| Text.deep_copy(@tasks[id]) }
      end

      def task(id)
        found = @tasks[id]
        found && Text.deep_copy(found)
      end

      def note_fault(sid, error, detail, now)
        detail = Text.str(detail)[0, FAULT_DETAIL_CHARS]
        old = @faults[sid]
        if old && old["active"] && old["error"] == error && old["detail"] == detail
          old["last_ts"] = iso(now)
          old["count"] = old.fetch("count", 1).to_i + 1
          return false
        end
        stamp = iso(now)
        @faults[sid] = { "active" => true, "error" => error, "detail" => detail, "first_ts" => stamp, "last_ts" => stamp, "count" => 1, "reopen" => true }
        true
      end

      def clear_fault(sid, now)
        old = @faults[sid]
        return unless old && old["active"]

        @faults[sid] = { "active" => false, "cleared_ts" => iso(now), "reopen" => old["reopen"] ? true : false }
      end

      def state
        Text.deep_copy({
          "tasks" => @order.map { |id| @tasks[id] },
          "touch" => @order.map { |id| @touch[id] },
          "sessions" => @sessions,
          "recent" => @recent,
          "faults" => @faults,
          "minted" => @minted,
          "seq" => @seq
        })
      end

      def restore(data)
        data = Text.deep_copy(data)
        @order = data["tasks"].map { |item| item["id"] }
        @tasks = data["tasks"].to_h { |item| [item["id"], item] }
        @touch = @order.zip(data["touch"]).to_h
        @sessions = data["sessions"]
        @recent = data["recent"]
        @faults = data["faults"]
        @minted = Hash.new(0).merge(data["minted"] || {})
        @seq = data["seq"]
        self
      end

      private

      def iso(epoch)
        Time.at(epoch).utc.strftime("%Y-%m-%dT%H:%M:%SZ")
      end

      def next_hex(kind, now, sid)
        key = "#{kind}|#{now}|#{sid}"
        count = @minted[key]
        @minted[key] = count + 1
        Digest::SHA256.hexdigest("#{key}|#{count}")[0, 4]
      end

      def task_id(now, sid)
        "t#{Time.at(now).utc.strftime('%Y%m%dT%H%M%S')}-#{next_hex('t', now, sid)}"
      end

      def decision_id(now, sid)
        "d#{(now * 1000).to_i}-#{next_hex('d', now, sid)}"
      end

      def present?(value)
        !value.nil? && value != false && value != ""
      end

      def repo_of(ev)
        Text.str(present?(ev["repo"]) ? ev["repo"] : ev["cwd"])
      end

      def prompt_event(ev, now)
        prompt = Text.str(ev["prompt"])
        marker = match_marker(prompt)
        return run_marker(ev, marker[0], marker[1], now) if marker
        return system_prompt(ev, now) if @prefixes.any? { |prefix| Text.lstrip(prompt).start_with?(prefix) }

        user_prompt(ev, now)
      end

      def new_session(sid, now)
        {
          "session_id" => sid, "task_id" => nil, "prev_task_id" => nil, "source" => nil, "prompts" => 0, "last_stop" => nil,
          "last_question" => false, "closing" => [], "pending_new" => false, "pin_next" => false, "ended" => false, "updated" => now
        }
      end

      def load_session(sid, now, create: true)
        record = @sessions[sid]
        return record if record
        return nil unless create

        @sessions[sid] = new_session(sid, now)
      end

      def save_session(record, now)
        record["updated"] = now
        @sessions[record["session_id"]] = record
      end

      def new_task(id, repo, started, name, via, decision)
        {
          "id" => id, "name" => name, "repo" => repo, "started" => started, "opened_by" => { "via" => via, "decision" => decision },
          "sessions" => [], "attached" => [], "turns" => [], "subagents" => [], "fingerprint" => [], "first_tokens" => [],
          "wip_counts" => {}, "last_activity" => started, "closed" => nil, "merged_into" => nil
        }
      end

      def live?(task, now)
        Totals.live?(task, now, @rules)
      end

      def current(record, now)
        id = record["task_id"]
        return [nil, false] unless id

        found = @tasks[id]
        if found && found["merged_into"]
          found = @tasks[found["merged_into"]]
          record["task_id"] = found["id"] if found
        end
        return [found, false] if found && !found["merged_into"] && live?(found, now)

        [nil, true]
      end

      def index(task, now, force)
        existing = @recent.find { |item| item["id"] == task["id"] }
        return if !force && existing && task["last_activity"] - existing["last_activity"] <= RECENT_DRIFT

        items = @recent.reject { |item| item["id"] == task["id"] || now - item.fetch("last_activity", 0) > RECENT_SECONDS }
        if now - task["last_activity"] <= RECENT_SECONDS
          items << { "id" => task["id"], "repo" => task["repo"], "last_activity" => task["last_activity"], "closed" => !task["closed"].nil? || present?(task["merged_into"]) }
        end
        @recent = items
      end

      def save_task(task, now, force: true)
        @order << task["id"] unless @tasks.key?(task["id"])
        @tasks[task["id"]] = task
        @touch[task["id"]] = (@seq += 1)
        index(task, now, force)
      end

      def log_close(task, now)
        values = Totals.totals(task, now, @rules)
        @log << {
          "ts" => iso(now), "event" => "close", "task" => task["id"], "reason" => task["closed"]["reason"],
          "elapsed" => Scoring.pyround(values[:elapsed], 1), "active" => Scoring.pyround(values[:active], 1),
          "agents" => Scoring.pyround(values[:agents], 1), "subagents" => values[:subagents]
        }
      end

      def leave(task, sid, reason, now)
        close_spans(task, sid, task["last_activity"])
        task["attached"].delete(sid)
        if task["attached"].empty? && task["closed"].nil?
          task["closed"] = { "at" => task["last_activity"], "reason" => reason }
          log_close(task, now)
        end
        save_task(task, now)
      end

      def release(record, sid, reason, now)
        id = record["task_id"]
        return nil unless id

        found = @tasks[id]
        leave(found, sid, reason, now) if found && !found["merged_into"]
        id
      end

      def create(repo, sid, now, name, via, decision, started: nil)
        task = new_task(task_id(now, sid), repo, started.nil? ? now : started, name, via, decision)
        task["sessions"] << sid
        task["attached"] << sid
        wip = repo.empty? ? nil : File.join(repo, ".rproject", "WIP.md")
        text = wip && @reader ? @reader.call(wip) : nil
        task["wip_counts"][wip] = Scoring.wip_count(text) unless text.nil?
        @log << { "ts" => iso(now), "event" => "open", "task" => task["id"], "repo" => repo, "via" => via, "decision" => decision, "session_id" => sid }
        task
      end

      def attach(task, sid)
        task["sessions"] << sid unless task["sessions"].include?(sid)
        task["attached"] << sid unless task["attached"].include?(sid)
      end

      def close_spans(task, sid, at)
        task["turns"].each do |turn|
          next unless turn["session_id"] == sid

          turn["spans"].each { |span| span[1] = [span[0], at].max if span[1].nil? }
        end
      end

      def last_turn(task, sid)
        task["turns"].reverse_each.find { |turn| turn["session_id"] == sid }
      end

      def open_span?(task, sid)
        task["turns"].any? { |turn| turn["session_id"] == sid && turn["spans"].any? { |span| span[1].nil? } }
      end

      def recompute_activity(task)
        points = [task["started"]]
        task["turns"].each do |turn|
          points << turn["at"]
          turn["spans"].each { |span| span.each { |value| points << value unless value.nil? } }
        end
        task["subagents"].each do |agent|
          points << agent["start"]
          points << agent["end"] unless agent["end"].nil?
        end
        task["last_activity"] = points.max
      end

      def add_fingerprint(task, words)
        known = task["fingerprint"].to_h { |word| [word, true] }
        words.each do |word|
          next if known.key?(word)

          known[word] = true
          task["fingerprint"] << word
        end
        excess = task["fingerprint"].length - FINGERPRINT_CAP
        return unless excess.positive?

        keep = task["first_tokens"].to_h { |word| [word, true] }
        kept = []
        task["fingerprint"].each do |word|
          if excess.positive? && !keep.key?(word)
            excess -= 1
            next
          end
          kept << word
        end
        task["fingerprint"] = kept.last(FINGERPRINT_CAP)
      end

      def add_turn(task, sid, pid, prompt, did, words, now)
        close_spans(task, sid, task["last_activity"])
        task["first_tokens"] = words.dup if task["turns"].empty?
        task["turns"] << turn_for(sid, pid, now, prompt, did)
        add_fingerprint(task, words)
        task["last_activity"] = now
      end

      def turn_for(sid, pid, now, prompt, did)
        { "session_id" => sid, "prompt_id" => pid, "at" => now, "head" => Text.head(prompt, Text::HEAD_CHARS), "decision" => did, "spans" => [[now, nil]], "closing" => [] }
      end

      def name_for(prompt, workflow)
        return Text.head(prompt, Text::NAME_CHARS) if workflow

        name = Text.head(Text.strip_tags(prompt), Text::NAME_CHARS)
        name.empty? ? "pasted content" : name
      end

      def features(task, now, prompt, repo, closing, cleared, question)
        parts = Text.words(Text.collapse(Text.strip_tags(prompt)))
        first = parts.empty? ? "" : parts.first.downcase.gsub(Text::EDGE, "")
        found = Text.tokens(prompt)
        overlap = Text.containment(found, task["fingerprint"])
        result = Scoring.score(@rules, [0.0, (now - task["last_activity"]) / 60].max, closing, repo != task["repo"], cleared, overlap, parts.length, first, question, found.length)
        [result, overlap]
      end

      def candidate(record, repo, now)
        skip = [record["task_id"], record["prev_task_id"]]
        best = nil
        @recent.each do |item|
          next if item["repo"] != repo || item["closed"] || skip.include?(item["id"])
          next if now - item["last_activity"] > @rules["link_window_minutes"] * 60

          best = item if best.nil? || item["last_activity"] > best["last_activity"]
        end
        return nil unless best

        found = @tasks[best["id"]]
        found && found["closed"].nil? && !found["merged_into"] ? found : nil
      end

      def workflow?(first)
        @rules["workflow_commands"].any? { |cmd| first.start_with?(cmd) && (first.length == cmd.length || first[cmd.length].match?(/[[:space:]]/)) }
      end

      def user_prompt(ev, now)
        sid = ev["session_id"]
        raw = Text.str(ev["prompt"])[0, Text::PROMPT_CHARS]
        prompt = Redact.text(raw)
        pid = ev["prompt_id"]
        record = load_session(sid, now)
        record["prompts"] += 1
        record["entrypoint"] = ev["entrypoint"] if !present?(record["entrypoint"]) && present?(ev["entrypoint"])
        repo = repo_of(ev)
        cur, stale = current(record, now)
        did = decision_id(now, sid)
        fault = @faults[sid]
        reopen = fault && fault["reopen"] ? true : false
        pin = record["pin_next"]
        record["pin_next"] = false
        pending = record["pending_new"]
        first = Text.lstrip(raw)
        workflow = workflow?(first)
        target = nil
        total = nil
        feats = {}
        if pin && cur
          verdict = "continue"
          rule = "after_marker"
          target = cur
        elsif pending
          record["pending_new"] = false
          verdict = "new"
          rule = "after_done"
        elsif workflow
          verdict = "new"
          rule = "workflow"
        elsif cur
          (total, feats), _overlap = features(cur, now, prompt, repo, record["closing"], false, record["last_question"])
          verdict = total >= @rules["new_threshold"] ? "new" : "continue"
          rule = "score"
          target = cur if verdict == "continue"
        elsif reopen
          verdict = "new"
          rule = "fault"
        else
          verdict = "new"
          rule = stale ? "stale" : "no_task"
          cand = candidate(record, repo, now)
          if cand
            closing = cand["turns"].empty? ? [] : cand["turns"].last["closing"]
            cleared = record["source"] == "clear" && record["prompts"] == 1
            (total, feats), overlap = features(cand, now, prompt, repo, closing, cleared, false)
            feats["entrypoint"] = { "value" => record["entrypoint"], "points" => 0 }
            if !overlap.nil? && overlap >= @rules["link_min_overlap"] && total < @rules["new_threshold"] && @rules["link_entrypoints"].include?(record["entrypoint"])
              verdict = "link"
              rule = "link"
              target = cand
            end
          end
        end
        words = Text.tokens(prompt)
        task_from = record["task_id"]
        if target
          if verdict == "link"
            release(record, sid, "new_task", now)
            record["prev_task_id"] = task_from || record["prev_task_id"]
          end
          attach(target, sid)
          add_turn(target, sid, pid, prompt, did, words, now)
          target["name"] = name_for(prompt, false) unless present?(target["name"])
          record["task_id"] = target["id"]
          task = target
        else
          left = release(record, sid, "new_task", now)
          task = create(repo, sid, now, name_for(prompt, rule == "workflow"), rule, did)
          task["first_tokens"] = words.dup
          task["fingerprint"] = words.dup
          task["turns"] << turn_for(sid, pid, now, prompt, did)
          record["prev_task_id"] = left if left
          record["task_id"] = task["id"]
        end
        save_task(task, now)
        @log << {
          "ts" => iso(now), "event" => "decision", "id" => did, "session_id" => sid, "prompt_id" => pid, "task_from" => task_from,
          "task_to" => task["id"], "verdict" => verdict, "rule" => rule, "score" => total, "threshold" => @rules["new_threshold"],
          "features" => feats, "prompt_head" => Text.head(prompt, Text::HEAD_CHARS)
        }
        record["closing"] = first.start_with?("/checkpoint") ? ["checkpoint"] : []
        save_session(record, now)
        fault["reopen"] = false if reopen
        nil
      end

      def system_prompt(ev, now)
        sid = ev["session_id"]
        record = load_session(sid, now, create: false)
        return nil unless record

        task, = current(record, now)
        return nil unless task

        turn = last_turn(task, sid)
        turn["spans"] << [now, nil] if turn && !open_span?(task, sid)
        task["last_activity"] = now
        save_task(task, now, force: false)
        nil
      end

      def tool(ev, now)
        sid = ev["session_id"]
        record = load_session(sid, now, create: false)
        return nil unless record

        task, = current(record, now)
        return nil unless task

        turn = last_turn(task, sid)
        turn["spans"] << [now, nil] if !present?(ev["agent_id"]) && turn && !open_span?(task, sid)
        hints = Scoring.closing_hints(task, ev, @reader)
        unless hints.empty?
          record["closing"].concat(hints)
          turn["closing"].concat(hints) if turn
        end
        Scoring.touched_tokens(ev).then { |words| add_fingerprint(task, words) } if Scoring::EDIT_TOOLS.include?(ev["tool_name"])
        task["last_activity"] = now
        save_task(task, now, force: false)
        save_session(record, now)
        nil
      end

      def stop(ev, now)
        sid = ev["session_id"]
        record = load_session(sid, now)
        record["last_stop"] = now
        record["last_question"] = Text.question?(ev["last_assistant_message"], @rules["question_cues"])
        task, = current(record, now)
        if task
          close_spans(task, sid, now)
          task["last_activity"] = now
          save_task(task, now, force: false)
        end
        save_session(record, now)
        nil
      end

      def subagent_start(ev, now)
        sid = ev["session_id"]
        agent = ev["agent_id"]
        return nil unless present?(agent)

        record = load_session(sid, now, create: false)
        return nil unless record

        task, = current(record, now)
        return nil unless task

        task["subagents"] << { "agent_id" => agent, "agent_type" => ev["agent_type"], "session_id" => sid, "start" => now, "end" => nil }
        task["last_activity"] = now
        save_task(task, now, force: false)
        nil
      end

      def subagent_stop(ev, now)
        sid = ev["session_id"]
        agent = ev["agent_id"]
        return nil unless present?(agent)

        record = load_session(sid, now, create: false)
        return nil unless record

        task, = current(record, now)
        candidates = task ? [task] : []
        if record["prev_task_id"]
          prev = @tasks[record["prev_task_id"]]
          candidates << prev if prev
        end
        candidates.each do |item|
          found = item["subagents"].find { |entry| entry["agent_id"] == agent }
          next if found.nil?

          found["end"] = now if found["end"].nil?
          item["last_activity"] = now
          save_task(item, now, force: false)
          return nil
        end
        nil
      end

      def session_start(ev, now)
        sid = ev["session_id"]
        record = load_session(sid, now)
        record["source"] = ev["source"]
        record["ended"] = false
        task = nil
        task, = current(record, now) if %w[resume compact].include?(record["source"])
        if task
          attach(task, sid)
          save_task(task, now, force: false)
        else
          record["task_id"] = nil
        end
        save_session(record, now)
        nil
      end

      def session_end(ev, now)
        sid = ev["session_id"]
        record = load_session(sid, now, create: false)
        return nil unless record

        task, = current(record, now)
        if task
          close_spans(task, sid, now)
          task["attached"].delete(sid)
          save_task(task, now, force: false)
        end
        record["ended"] = true
        save_session(record, now)
        nil
      end
    end
  end
end
