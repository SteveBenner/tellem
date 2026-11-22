# frozen_string_literal: true

require_relative "../bounds"
require_relative "../ids"
require_relative "../redact"
require_relative "../record/fs"
require_relative "../record/reader"
require_relative "batch"
require_relative "claude"
require_relative "support"

module Tellem
  module Ingest
    module ClaudeBodies
      HARNESS = "claude"
      INDEX = "index.jsonl"
      INDEX_KEYS = %w[timestamp session_id query_source model request_id message_id message_uuid request_file response_file].freeze
      REQUIRED_INDEX_KEYS = %w[timestamp session_id query_source request_id message_id request_file response_file].freeze
      REQUEST_FILE = /\A[A-Za-z0-9_-]{1,128}\.request\.json\z/.freeze
      RESPONSE_FILE = /\A[A-Za-z0-9_-]{1,128}\.response\.json\z/.freeze
      BODY_BYTES = 67_108_864
      MAIN_SOURCES = %w[repl_main_thread sdk].freeze
      AGENT_PREFIX = "agent:"
      SIDEBAND = %w[generate_session_title prompt_suggestion compact].freeze
      ROLES = %w[user assistant system].freeze
      ORPHAN = "orphan-"
      REMINDER = %r{\A\s*(?:<system-reminder>.*?</system-reminder>\s*)+\z}m.freeze
      NOTICE = %r{\A\s*<system-reminder>\s*(\[SYSTEM NOTIFICATION.*?)\s*</system-reminder>\s*\z}m.freeze
      NOTICE_BANNER = "[SYSTEM NOTIFICATION"
      PEER_MESSAGE = "Another Claude session sent a message"
      COORDINATOR_MESSAGE = "The coordinator sent a message"
      HANDBACK_NOTICE = "[handback-send-enforce]"
      COMPACT_SUMMARY = "This session is being continued from a previous conversation"
      COMPACT_COMMAND = "<command-name>/compact</command-name>"
      COMPACT_ECHO = "/compact"
      COMMAND_ARGS = %r{<command-args>(.*?)</command-args>}m.freeze
      COMMAND_CAVEAT = "<local-command-caveat>"
      COMMAND_OUTPUT = "<local-command-stdout>"
      TOOL_LOADED = "Tool loaded."
      THINKING = %w[thinking redacted_thinking].freeze
      UNAVAILABLE = "redacted_by_harness"
      SHAPE = "shape_unrecognized"
      UNATTRIBUTED = "body_unattributed"
      CONFLICT = "body_attribution_conflict"
      UNSAFE = "spool_unsafe"
      MISSING = "missing"
      REQUIRED_MODE = 0o700
      NOT_RECORDED = "not_recorded"
      BODY_MARKS = [NOT_RECORDED, "body_withheld", "body_truncated", "truncated"].freeze
      INTERRUPTED = "native_only_request"

      class Evidence
        attr_reader :tools

        def initialize(raw)
          @tools = {}
          @places = {}
          raw.each do |agent, records|
            @places[agent] = records.filter_map { |record| [record["ts"], record["cwd"]] if record["cwd"].is_a?(String) && record["ts"].is_a?(String) }
            records.each { |record| @tools[record["tool_use_id"]] ||= agent if record["tool_use_id"].is_a?(String) }
          end
        end

        def agent_of(tool_use_id)
          @tools[tool_use_id]
        end

        def cwd(agent, ts)
          place(@places[agent], ts) || place(@places[Ids::MAIN_AGENT], ts)
        end

        def place(marks, ts)
          return nil if marks.nil? || marks.empty?

          found = marks.select { |mark| mark[0] <= ts.to_s }.last || marks.first
          found[1]
        end
      end

      class View
        attr_reader :agents, :gaps, :sideband, :ingested, :held_back, :mine

        def initialize
          @agents = {}
          @gaps = []
          @sideband = []
          @ingested = []
          @held_back = []
          @mine = 0
        end

        def gap(cause, suffix, detail: {}, count: 1)
          existing = @gaps.find { |entry| entry["cause"] == cause && entry["suffix"] == suffix }
          return existing["count"] += count if existing

          @gaps << { "cause" => cause, "suffix" => suffix, "detail" => detail, "count" => count }
        end

        def count_line
          @mine += 1
        end
      end

      module_function

      def read(path, session_id:, agent_key:, from: nil, evidence: nil)
        view = view(File.dirname(path), session_id: session_id, evidence: evidence || Evidence.new({}), from: from)
        batch_for(view.agents[agent_key] || [], session_id: session_id, agent_key: agent_key, gaps: view.gaps)
      end

      def batch_for(lines, session_id:, agent_key:, gaps: [], version: nil)
        batch = Batch.new(harness: HARNESS, session_id: session_id, agent_key: agent_key)
        state = { requests: {}, order: [], version: version, model: nil }
        lines.each { |line| Claude.entry(batch, state, line) }
        gaps.each { |entry| batch.add_gap(entry["cause"], suffix: entry["suffix"], detail: entry["detail"], count: entry["count"]) }
        batch.usage = state[:order].map { |key| state[:requests][key] }
        batch.model = state[:model]
        batch.finish(harness_version: version, cursor: nil)
      end

      def view(dir, session_id:, evidence:, held: {}, done: {}, version: nil, from: nil, ready: nil, final: true)
        out = View.new
        reason = unsafe_reason(dir)
        if reason
          out.gap(UNSAFE, reason, detail: { "reason" => reason }) unless reason == MISSING
          return out
        end

        requests = load(dir, session_id, done, out, from, final)
        chains = link(requests, held_messages(held))
        attribute(chains, requests, evidence, out)
        known = held.transform_values { |lines| fingerprints(lines) }
        requests.sort_by { |request| [request["ts"], request["seq"]] }.each do |request|
          agent = request["agent"]
          case request["class"]
          when :sideband then sideband(out, request)
          when :agent then emit(out, request, agent, known, evidence, version)
          when :unknown then unresolved(out, request, ready)
          when :discard then out.ingested << request
          end
        end
        out
      end

      def unsafe_reason(path)
        stat = Record::FS.lstat(path)
        return MISSING unless stat
        return "not_a_directory" unless stat.directory? && !stat.symlink?
        return "wrong_owner" unless stat.uid == Process.euid
        return "wrong_mode" unless (stat.mode & 0o777) == REQUIRED_MODE

        nil
      end

      def held_messages(held)
        held.each_with_object({}) do |(agent, lines), map|
          lines.each do |line|
            id = line.dig("message", "id")
            map[id] = agent if id.is_a?(String)
          end
        end
      end

      def load(dir, session_id, done, out, from, final)
        seen = {}
        list = []
        named = {}
        cursor = Record::Reader.each(File.join(dir, INDEX), from: from) do |line|
          named[File.basename(line["request_file"])] = true if line["request_file"].is_a?(String)
          next unless line["session_id"] == session_id

          out.count_line
          id = line["request_id"]
          out.ingested << { "id" => id, "files" => listed_files(dir, line) } if id.is_a?(String) && done[id]
          next if id.is_a?(String) && (seen[id] || done[id])

          seen[id] = true if id.is_a?(String)
          request = from_index(dir, line, out)
          list << request.merge("seq" => list.size) if request
        end
        out.gap("torn_line", INDEX, detail: { "lines" => cursor["torn"] }, count: cursor["torn"]) if cursor["torn"].positive?
        final ? list + orphans(dir, session_id, named, done, list.size, out) : list
      end

      def listed_files(dir, line)
        [[line["request_file"], REQUEST_FILE], [line["response_file"], RESPONSE_FILE]].filter_map do |name, pattern|
          file_path(dir, name) if name.is_a?(String) && pattern.match?(File.basename(name))
        end
      end

      def orphans(dir, session_id, named, done, start, out)
        names = Dir.children(dir).select { |name| REQUEST_FILE.match?(name) && !named[name] }.sort
        finished, open = names.partition { |name| done["#{ORPHAN}#{name}"] }
        finished.each { |name| out.ingested << { "id" => "#{ORPHAN}#{name}", "files" => [file_path(dir, name)] } }
        found = open.filter_map { |name| orphan(dir, name, session_id, out) }
        out.gap(INTERRUPTED, "interrupted", detail: { "requests" => found.size }, count: found.size) unless found.empty?
        found.each_with_index.map { |request, offset| request.merge("seq" => start + offset) }
      rescue Errno::ENOENT
        []
      end

      def orphan(dir, name, session_id, out)
        request = body(dir, name, REQUEST_FILE, out)
        return nil unless request && owner(request) == session_id
        return nil unless request["messages"].is_a?(Array) && request["messages"].all? { |item| known_message?(item) }

        path = File.join(dir, name)
        written = written_at(path)
        { "line" => { "query_source" => nil, "message_id" => nil }, "request" => request, "response" => nil, "orphan" => true, "id" => "#{ORPHAN}#{name}",
          "ts" => written, "sent" => written, "files" => [path] }
      end

      def owner(request)
        meta = JSON.parse(request.dig("metadata", "user_id").to_s)
        meta.is_a?(Hash) ? meta["session_id"] : nil
      rescue JSON::ParserError
        nil
      end

      def from_index(dir, line, out)
        extra = line.keys - INDEX_KEYS
        out.gap(SHAPE, "index:keys", detail: { "keys" => Support.safe_keys(line.slice(*extra)) }) unless extra.empty?
        missing = REQUIRED_INDEX_KEYS.reject { |key| line[key].is_a?(String) && !line[key].empty? }
        unless missing.empty?
          out.gap(SHAPE, "index:missing", detail: { "missing_keys" => missing.sort })
          return nil
        end

        request = body(dir, line["request_file"], REQUEST_FILE, out)
        response = body(dir, line["response_file"], RESPONSE_FILE, out)
        return nil unless request && response && recognized?(line, request, response, out)

        ts = Support.rfc3339_ms(line["timestamp"])
        unless ts
          out.gap(SHAPE, "index:timestamp")
          return nil
        end

        { "line" => line, "request" => request, "response" => response, "ts" => ts, "sent" => [written_at(file_path(dir, line["request_file"])), ts].min, "id" => line["request_id"],
          "files" => [file_path(dir, line["request_file"]), file_path(dir, line["response_file"])] }
      end

      def written_at(path)
        Record::FS.rfc3339_ms((File.lstat(path).mtime.to_r * 1_000_000_000).to_i)
      end

      def file_path(dir, name)
        File.join(dir, File.basename(name))
      end

      def body(dir, name, pattern, out)
        base = File.basename(name)
        unless pattern.match?(base)
          out.gap(SHAPE, "index:file_name")
          return nil
        end

        path = File.join(dir, base)
        stat = Record::FS.lstat(path)
        unless stat&.file?
          out.gap("body_missing", base.sub(/\A.*?\./, ""), detail: { "files" => 1 })
          return nil
        end
        if stat.size > BODY_BYTES
          out.gap("body_too_large", base.sub(/\A.*?\./, ""), detail: { "limit" => BODY_BYTES, "bytes" => stat.size })
          return nil
        end
        parsed = JSON.parse(Record::FS.read(path), max_nesting: Bounds::NESTING_DEPTH + 64)
        return parsed if parsed.is_a?(Hash)

        out.gap(SHAPE, "body:not_object")
        nil
      rescue JSON::ParserError, EncodingError
        out.gap(SHAPE, "body:unparsable")
        nil
      end

      def marked(body)
        return nil unless body.is_a?(Hash)

        found = BODY_MARKS.find { |name| body.key?(name) }
        return found if found

        Array(body["content"]).grep(Hash).each do |block|
          return NOT_RECORDED if block["input"].is_a?(Hash) && block["input"].key?(NOT_RECORDED)
        end
        nil
      end

      def recognized?(line, request, response, out)
        mark = marked(request) || marked(response)
        if mark
          out.gap("body_marked", mark, detail: { "mark" => mark })
          return false
        end

        problems = []
        problems << "request.messages" unless request["messages"].is_a?(Array) && request["messages"].all? { |item| known_message?(item) }
        problems << "response.id" unless response["id"].is_a?(String)
        problems << "response.message_id" unless response["id"] == line["message_id"]
        problems << "response.content" unless response["content"].is_a?(Array)
        problems << "response.usage" unless response["usage"].is_a?(Hash)
        problems << "thread" unless request["thread"].nil? || request["thread"].is_a?(Hash)
        return true if problems.empty?

        problems.each { |name| out.gap(SHAPE, name, detail: { "field" => name }) }
        false
      end

      def known_message?(message)
        message.is_a?(Hash) && ROLES.include?(message["role"]) && (message["content"].is_a?(String) || message["content"].is_a?(Array))
      end

      def link(requests, held_messages = {})
        by_message = {}
        chains = Hash.new { |hash, key| hash[key] = [] }
        requests.sort_by { |request| [request["ts"], request["seq"]] }.each do |request|
          previous = request.dig("request", "thread", "previous_message_id")
          chain = previous.is_a?(String) ? by_message[previous] : nil
          chain ||= request["seq"]
          request["chain"] = chain
          request["held_agent"] = held_messages[previous] if previous.is_a?(String)
          request["delta"] = request.dig("request", "thread", "type") == "continue"
          by_message[request["line"]["message_id"]] = chain if request["line"]["message_id"]
          chains[chain] << request
        end
        chains
      end

      def attribute(chains, requests, evidence, out)
        chains.each_value do |members|
          source = members.find { |request| request["line"]["query_source"] }&.dig("line", "query_source")
          agent = chain_agent(source, members, evidence, out)
          members.each do |request|
            request["class"] = request_class(request, agent)
            request["agent"] = agent
          end
        end
        requests
      end

      def request_class(request, agent)
        return :discard if request["orphan"] && !request["request"]["thread"].is_a?(Hash)
        return :sideband if SIDEBAND.include?(request["line"]["query_source"])
        return :agent if agent

        :unknown
      end

      def chain_agent(source, members, evidence, out)
        return Ids::MAIN_AGENT if MAIN_SOURCES.include?(source)
        return nil if SIDEBAND.include?(source)

        unless source.nil? || source.start_with?(AGENT_PREFIX)
          out.gap(SHAPE, "query_source:#{Support.safe_token(source)}", detail: { "query_source" => Support.safe_token(source) })
          return nil
        end

        inherited = members.filter_map { |request| request["held_agent"] }.uniq
        return inherited.first if inherited.size == 1

        direct = members.flat_map { |request| response_tools(request) }.filter_map { |id| evidence.agent_of(id) }.uniq - [Ids::MAIN_AGENT]
        direct = members.flat_map { |request| history_tools(request) }.filter_map { |id| evidence.agent_of(id) }.uniq - [Ids::MAIN_AGENT] if direct.empty?
        return direct.first if direct.size == 1

        out.gap(CONFLICT, "chain", detail: { "agents" => direct.size }) if direct.size > 1
        nil
      end

      def response_tools(request)
        return [] unless request["response"]

        Array(request["response"]["content"]).filter_map { |block| block["id"] if block.is_a?(Hash) && block["type"] == "tool_use" }
      end

      def history_tools(request)
        request["request"]["messages"].flat_map do |message|
          next [] unless message["content"].is_a?(Array)

          message["content"].filter_map do |block|
            next unless block.is_a?(Hash)

            block["type"] == "tool_use" ? block["id"] : block["tool_use_id"]
          end
        end.uniq
      end

      def unresolved(out, request, ready)
        out.held_back << request["id"]
        return if ready && !ready.call(request["ts"])

        out.gap(UNATTRIBUTED, Support.safe_token(request["line"]["query_source"] || ORPHAN), detail: { "requests" => 1 })
      end

      def sideband(out, request)
        out.sideband << {
          "type" => "body-sideband", "bodyRequest" => request["id"], "timestamp" => request["ts"],
          "query_source" => request["line"]["query_source"], "model" => request["response"]["model"], "usage" => numeric(request["response"]["usage"])
        }
        out.ingested << request
      end

      def numeric(usage)
        usage.select { |_key, value| value.is_a?(Integer) }
      end

      def emit(out, request, agent, known, evidence, version)
        marks = (known[agent] ||= [])
        base = base_line(request, agent, evidence, version)
        lines = request_lines(request, base.merge("timestamp" => request["sent"]), marks) + response_lines(request, base, marks)
        (out.agents[agent] ||= []).concat(lines)
        out.ingested << request
      end

      def base_line(request, agent, evidence, version)
        base = { "timestamp" => request["ts"], "bodyRequest" => request["id"], "bodySource" => request["line"]["query_source"] }.compact
        base["agentId"] = agent unless agent == Ids::MAIN_AGENT
        base["version"] = version if version
        cwd = evidence.cwd(agent, request["ts"])
        base["cwd"] = cwd if cwd
        base
      end

      def request_lines(request, base, marks)
        messages = request["request"]["messages"]
        return delta_lines(messages, base, marks, request["orphan"] ? marks.dup : []) if request["delta"]

        history_lines(messages, base, marks)
      end

      def delta_lines(messages, base, marks, already)
        messages.flat_map do |message|
          next [] unless message["role"] == "user"

          user_blocks(message, base).filter_map do |normal|
            print = mark(normal)
            next if already.include?(print)

            marks << print
            user_line(base, normal)
          end
        end
      end

      def history_lines(messages, base, marks)
        walk = { position: 0, leading: true, marks: marks, base: base, compacted: compacted?(messages) }
        lines = messages.flat_map do |message|
          next [] if message["role"] == "system"

          message["role"] == "user" ? history_user(message, walk) : history_agent(message, walk)
        end
        walk[:compacted] ? compaction_order(lines, base) : lines
      end

      def compacted?(messages)
        first = messages.find { |message| message["role"] == "user" }
        block = first && blocks(first).first
        block.is_a?(Hash) && block["text"].to_s.start_with?(COMPACT_SUMMARY)
      end

      def compaction_order(lines, base)
        summaries, others = lines.partition { |line| line["isCompactSummary"] }
        at = others.index { |line| line_text(line).start_with?(COMMAND_OUTPUT) } || others.size
        ordered = others.first(at) + summaries + others.drop(at)
        at = ordered.index { |line| line_text(line).start_with?(COMPACT_COMMAND) }
        return ordered unless at

        before = at.positive? && line_text(ordered[at - 1]).start_with?(COMMAND_CAVEAT) ? at - 1 : at
        ordered.insert(before, user_line(base, { "type" => "text", "text" => compact_echo(line_text(ordered[at])) }))
      end

      def compact_echo(command)
        args = command[COMMAND_ARGS, 1].to_s.strip
        args.empty? ? COMPACT_ECHO : "#{COMPACT_ECHO} #{args}"
      end

      def line_text(line)
        block = Array(line.dig("message", "content")).first
        block.is_a?(Hash) ? block["text"].to_s : ""
      end

      def history_user(message, walk)
        list = user_blocks(message, walk[:base], leading: walk[:leading], reminders: !walk[:compacted])
        walk[:leading] = false
        list.filter_map { |normal| user_line(walk[:base], normal) if unseen?(normal, walk) }
      end

      def history_agent(message, walk)
        walk[:leading] = false
        thinking = []
        blocks(message).flat_map do |block|
          normal = assistant_block(block)
          if THINKING.include?(normal["type"])
            thinking << normal
            next []
          end

          next [] unless unseen?(normal, walk)

          pending = thinking
          thinking = []
          (pending + [normal]).map { |item| history_assistant(walk[:base], item) }
        end
      end

      def unseen?(normal, walk)
        print = mark(normal)
        found = walk[:marks][walk[:position]..]&.index(print)
        if found
          walk[:position] += found + 1
          return false
        end

        walk[:marks].insert(walk[:position], print)
        walk[:position] += 1
        true
      end

      def blocks(message)
        content = message["content"]
        return [{ "type" => "text", "text" => content }] if content.is_a?(String)

        content.select { |block| block.is_a?(Hash) }
      end

      def user_blocks(message, base, leading: false, reminders: true)
        list = blocks(message)
        list = list.drop_while { |block| reminder?(block) } if leading
        list = list.reject { |block| reminder?(block) } unless reminders
        loaded = list.any? { |block| tool_reference?(block) }
        list.filter_map do |block|
          next if loaded && block["type"] == "text" && block["text"] == TOOL_LOADED

          user_block(block, base)
        end
      end

      def reminder?(block)
        block["type"] == "text" && REMINDER.match?(block["text"].to_s)
      end

      def tool_reference?(block)
        block["type"] == "tool_result" && block["content"].is_a?(Array) && block["content"].any? { |part| part.is_a?(Hash) && part["type"] == "tool_reference" }
      end

      def user_block(block, base)
        case block["type"]
        when "text"
          text = block["text"]
          return nil unless text.is_a?(String)

          { "type" => "text", "text" => unwrap(text, base) }
        when "tool_result"
          { "type" => "tool_result", "tool_use_id" => block["tool_use_id"], "content" => result_content(block["content"]), "is_error" => block["is_error"] }.compact
        when "image", "document" then { "type" => block["type"] }
        else block
        end
      end

      def unwrap(text, base)
        wrapped = NOTICE.match(text)
        return text unless wrapped

        base.key?("agentId") ? wrapped[1] : wrapped[1][/<task-notification>.*\z/m] || wrapped[1]
      end

      def result_content(content)
        return content unless content.is_a?(Array)

        content.map do |part|
          next part unless part.is_a?(Hash)

          part["text"].is_a?(String) ? { "type" => part["type"], "text" => part["text"] } : { "type" => part["type"] }
        end
      end

      def assistant_block(block)
        case block["type"]
        when *THINKING then { "type" => block["type"], "thinking" => "", "unavailable" => UNAVAILABLE }
        when "text" then { "type" => "text", "text" => block["text"] }
        when "tool_use", "server_tool_use" then { "type" => block["type"], "id" => block["id"], "name" => block["name"], "input" => block["input"] }
        else block
        end
      end

      def mark(block)
        case block["type"]
        when "text" then ["text", Ids.sha256(Redact.text(block["text"].to_s).gsub(/\s+/, " ").strip)]
        when "tool_use", "server_tool_use" then ["tool", block["id"]]
        when "tool_result" then ["result", block["tool_use_id"]]
        when *THINKING then nil
        else [block["type"], Ids.sha256(JSON.generate(block))]
        end
      end

      def fingerprints(lines)
        lines.flat_map { |line| Array(line.dig("message", "content")) }.filter_map { |block| mark(block) if block.is_a?(Hash) }
      end

      def user_line(base, block)
        line = base.merge("type" => "user", "message" => { "role" => "user", "content" => [block] })
        return line unless block["type"] == "text"

        line["isCompactSummary"] = true if block["text"].start_with?(COMPACT_SUMMARY)
        line["isMeta"] = true if meta_text?(block["text"], base)
        line
      end

      def meta_text?(text, base)
        return true if text.start_with?(PEER_MESSAGE, COORDINATOR_MESSAGE, COMMAND_CAVEAT, HANDBACK_NOTICE) || REMINDER.match?(text)

        base.key?("agentId") && text.start_with?(NOTICE_BANNER)
      end

      def history_assistant(base, block)
        base.merge("type" => "assistant", "message" => { "role" => "assistant", "content" => [block] })
      end

      def response_lines(request, base, marks)
        response = request["response"]
        return [] unless response

        content = Array(response["content"]).select { |block| block.is_a?(Hash) }
        message = { "role" => "assistant", "id" => response["id"], "model" => response["model"], "usage" => response["usage"],
                    "stop_reason" => response["stop_reason"] }
        common = base.merge("type" => "assistant", "requestId" => request["id"], "uuid" => request["line"]["message_uuid"])
        return [common.merge("message" => message.merge("content" => []))] if content.empty?

        content.map do |block|
          normal = assistant_block(block)
          print = mark(normal)
          marks << print if print
          common.merge("message" => message.merge("content" => [normal]))
        end
      end
    end
  end
end
