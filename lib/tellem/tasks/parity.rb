# frozen_string_literal: true

require "json"
require "time"
require_relative "../bounds"
require_relative "../errors"
require_relative "totals"

module Tellem
  module Tasks
    module Parity
      TOLERANCE_S = 1.0
      MATCH_WINDOW_S = 2.0
      CAUSES = %w[boundary name turns subagents elapsed active agents].freeze
      TIMES = %i[elapsed active agents].freeze
      TASK_DIR = "t"
      SESSION_DIR = "s"
      SUFFIX = ".json"
      NESTING = 16

      module_function

      def store(path)
        root = begin
          File.realpath(File.expand_path(path.to_s))
        rescue SystemCallError
          nil
        end
        unless root && File.directory?(root)
          raise OperationalFailure.new("the task clock store #{path} is not a readable directory",
                                       next_command: "tellem tasks parity --against ~/.local/state/agent-clock/tasks")
        end

        unreadable = []
        tasks = read_dir(root, TASK_DIR, unreadable).filter_map do |item|
          next item[:data] if usable?(item[:data])

          unreadable << { file: item[:file], reason: "not a task" }
          nil
        end
        sessions = read_dir(root, SESSION_DIR, unreadable).select { |item| item[:data]["session_id"].is_a?(String) }
        {
          root: root,
          tasks: tasks,
          sessions: sessions.to_h { |item| [item[:data]["session_id"], item[:data]] },
          unreadable: unreadable.map { |item| { "file" => item[:file], "reason" => item[:reason] } }
        }
      end

      def read_dir(root, name, unreadable)
        dir = File.join(root, name)
        stat = File.lstat(dir)
        return [] unless stat.directory?

        Dir.children(dir).sort.filter_map do |entry|
          next unless entry.end_with?(SUFFIX)

          file = File.join(name, entry)
          data = read_file(File.join(dir, entry), file, unreadable)
          data && { file: file, data: data }
        end
      rescue SystemCallError
        []
      end

      def read_file(path, file, unreadable)
        stat = File.lstat(path)
        unless stat.file?
          unreadable << { file: file, reason: "not a regular file" }
          return nil
        end
        text, over, = File.open(path, File::RDONLY | File::NOFOLLOW) { |io| Bounds.read_bounded(io) }
        if over
          unreadable << { file: file, reason: "larger than the record bound" }
          return nil
        end
        data = JSON.parse(text, max_nesting: NESTING)
        return data if data.is_a?(Hash)

        unreadable << { file: file, reason: "not an object" }
        nil
      rescue JSON::ParserError, EncodingError, SystemCallError
        unreadable << { file: file, reason: "unreadable" }
        nil
      end

      def number?(value)
        value.is_a?(Numeric) && (!value.is_a?(Float) || value.finite?)
      end

      def usable?(task)
        return false unless task.is_a?(Hash) && task["id"].is_a?(String) && number?(task["started"]) && number?(task["last_activity"])
        return false unless task["sessions"].is_a?(Array) && task["sessions"].all?(String)
        return false unless task["turns"].is_a?(Array) && task["turns"].all? { |turn| turn_ok?(turn) }

        task["subagents"].is_a?(Array) && task["subagents"].all? do |agent|
          agent.is_a?(Hash) && number?(agent["start"]) && (agent["end"].nil? || number?(agent["end"]))
        end
      end

      def turn_ok?(turn)
        turn.is_a?(Hash) && turn["spans"].is_a?(Array) && turn["spans"].all? do |span|
          span.is_a?(Array) && span.length == 2 && number?(span[0]) && (span[1].nil? || number?(span[1]))
        end
      end

      def compare(stored, derived, rules, now)
        pairs, only_stored, only_derived = match(stored[:tasks], derived)
        rows = pairs.map { |left, right| pair_row(left, right, rules, now) }
        rows.concat(only_stored.map { |task| lone_row("only_stored", task) })
        rows.concat(only_derived.map { |task| lone_row("only_derived", task) })
        rows.sort_by! { |row| [row["started"], row["stored_id"].to_s, row["derived_id"].to_s] }
        matched = rows.select { |row| %w[identical differs].include?(row["status"]) }
        {
          "now" => Time.at(now).utc.strftime("%Y-%m-%dT%H:%M:%SZ"),
          "tolerance_s" => TOLERANCE_S,
          "match_window_s" => MATCH_WINDOW_S,
          "stored" => { "tasks" => stored[:tasks].length, "sessions" => stored[:sessions].length, "unreadable" => stored[:unreadable] },
          "derived" => { "tasks" => derived.length },
          "matched" => matched.length,
          "identical" => rows.count { |row| row["status"] == "identical" },
          "differing" => rows.count { |row| row["status"] == "differs" },
          "only_stored" => only_stored.length,
          "only_derived" => only_derived.length,
          "by_cause" => CAUSES.to_h { |cause| [cause, matched.count { |row| row["causes"].include?(cause) }] },
          "totals" => { "stored" => sums(stored[:tasks], rules, now), "derived" => sums(derived, rules, now) },
          "sessions" => session_rows(stored, derived, rows),
          "tasks" => rows
        }
      end

      def match(stored, derived)
        free = derived.sort_by { |task| [task["started"], task["id"]] }
        pairs = []
        lone = []
        stored.sort_by { |task| [task["started"], task["id"]] }.each do |task|
          found = free.select { |item| near?(task, item) }.min_by { |item| [(item["started"] - task["started"]).abs, item["id"]] }
          if found
            free.delete(found)
            pairs << [task, found]
          else
            lone << task
          end
        end
        [pairs, lone, free]
      end

      def near?(left, right)
        (left["sessions"] & right["sessions"]).any? && (left["started"] - right["started"]).abs <= MATCH_WINDOW_S
      end

      def values(task, rules, now)
        Totals.totals(task, now, rules)
      end

      def pair_row(left, right, rules, now)
        a = values(left, rules, now)
        b = values(right, rules, now)
        found = {}
        boundary(left, right, found)
        found["name"] = { "stored" => left["name"], "derived" => right["name"] } if left["name"].to_s.strip != right["name"].to_s.strip
        found["turns"] = { "stored" => left["turns"].length, "derived" => right["turns"].length } if left["turns"].length != right["turns"].length
        found["subagents"] = { "stored" => a[:subagents], "derived" => b[:subagents] } if a[:subagents] != b[:subagents]
        TIMES.each do |field|
          found[field.to_s] = { "stored" => a[field].round(1), "derived" => b[field].round(1) } if (a[field] - b[field]).abs > TOLERANCE_S
        end
        causes = CAUSES.select { |cause| found.key?(cause) }
        {
          "status" => causes.empty? ? "identical" : "differs", "stored_id" => left["id"], "derived_id" => right["id"],
          "sessions" => (left["sessions"] | right["sessions"]).sort, "started" => left["started"], "name" => left["name"],
          "causes" => causes, "differences" => found
        }
      end

      def boundary(left, right, found)
        stored = {}
        derived = {}
        if (left["started"] - right["started"]).abs > TOLERANCE_S
          stored["started"] = left["started"]
          derived["started"] = right["started"]
        end
        if left["sessions"].sort != right["sessions"].sort
          stored["sessions"] = left["sessions"].sort
          derived["sessions"] = right["sessions"].sort
        end
        if left["closed"].nil? != right["closed"].nil?
          stored["closed"] = !left["closed"].nil?
          derived["closed"] = !right["closed"].nil?
        end
        if left["merged_into"].to_s.empty? != right["merged_into"].to_s.empty?
          stored["merged"] = !left["merged_into"].to_s.empty?
          derived["merged"] = !right["merged_into"].to_s.empty?
        end
        found["boundary"] = { "stored" => stored, "derived" => derived } unless stored.empty?
      end

      def lone_row(status, task)
        {
          "status" => status, "stored_id" => status == "only_stored" ? task["id"] : nil, "derived_id" => status == "only_derived" ? task["id"] : nil,
          "sessions" => task["sessions"].sort, "started" => task["started"], "name" => task["name"], "causes" => [], "differences" => {}
        }
      end

      def sums(tasks, rules, now)
        list = tasks.map { |task| values(task, rules, now) }
        { "tasks" => tasks.length, "turns" => tasks.sum { |task| task["turns"].length }, "subagents" => list.sum { |item| item[:subagents] } }
          .merge(TIMES.to_h { |field| [field.to_s, list.sum { |item| item[field] }.round(1)] })
      end

      def session_rows(stored, derived, rows)
        ids = (stored[:tasks].flat_map { |task| task["sessions"] } + derived.flat_map { |task| task["sessions"] } + stored[:sessions].keys).uniq.sort
        ids.map do |id|
          touching = rows.select { |row| row["sessions"].include?(id) }
          {
            "session_id" => id,
            "stored_tasks" => stored[:tasks].count { |task| task["sessions"].include?(id) },
            "derived_tasks" => derived.count { |task| task["sessions"].include?(id) },
            "matched" => touching.count { |row| %w[identical differs].include?(row["status"]) },
            "differing" => touching.count { |row| row["status"] == "differs" },
            "only_stored" => touching.count { |row| row["status"] == "only_stored" },
            "only_derived" => touching.count { |row| row["status"] == "only_derived" },
            "stored_turns" => turns(stored[:tasks], id),
            "derived_turns" => turns(derived, id),
            "clock_prompts" => stored[:sessions].dig(id, "prompts"),
            "causes" => touching.flat_map { |row| row["causes"] }.tally.sort.to_h
          }
        end
      end

      def turns(tasks, id)
        tasks.sum { |task| task["turns"].count { |turn| turn["session_id"] == id } }
      end
    end
  end
end
