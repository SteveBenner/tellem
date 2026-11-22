# frozen_string_literal: true

require "json"
require "time"
require_relative "../deriver/context"
require_relative "../deriver/session"
require_relative "../deriver/sources"
require_relative "../deriver/spool"
require_relative "../ids"
require_relative "../ingest/claude_bodies"
require_relative "../ports/harness_paths"
require_relative "../record/scope"
require_relative "../reports/text"
require_relative "../transcript/markdown"
require_relative "turns"

module Tellem
  module Parity
    module Bodies
      HARNESS = "claude"
      PARITY = "parity"
      MISMATCH = "mismatch"
      NO_REFERENCE = "no_native"
      NO_BODIES = "no_bodies"
      USAGE_FIELDS = %w[
        provider_request_id model stop_reason service_tier cwd input_tokens output_tokens cache_read_input_tokens cache_creation_input_tokens
        total_tokens inference_geo speed cache_creation_ephemeral_1h_input_tokens cache_creation_ephemeral_5m_input_tokens
        server_tool_use_web_search_requests server_tool_use_web_fetch_requests
      ].freeze
      DIGEST_HEX = 16
      TERMINAL_RESULT = "terminal_tool_result_not_in_bodies"
      ENRICHED_INPUT = "tool_input_enriched_after_the_wire"
      TIMESTAMPS = "timestamps_differ"
      REASONING_TEXT = "reasoning_text_only_in_native"

      module_function

      def run(scopes, session: nil, dir: Ports::HarnessPaths.body_spool)
        unsafe = Ingest::ClaudeBodies.unsafe_reason(dir)
        return { "spool" => dir, "spool_unsafe" => unsafe, "sessions" => [], "criteria" => { "considered" => 0, "passing" => 0, "met" => false } } if unsafe

        rows = scopes.reject { |scope| scope["gone"] }.flat_map { |scope| scope_rows(scope["root"], session, dir) }
        considered = rows.reject { |row| [NO_REFERENCE, NO_BODIES].include?(row["verdict"]) }
        { "spool" => dir, "sessions" => rows,
          "criteria" => { "considered" => considered.size, "passing" => considered.count { |row| row["verdict"] == PARITY },
                          "met" => !considered.empty? && considered.all? { |row| row["verdict"] == PARITY } } }
      end

      def scope_rows(root, filter, dir)
        keys = Record::Scope.session_keys(root).select { |key| key.start_with?("#{HARNESS}-") && wanted?(key, filter) }
        return [] if keys.empty?

        context = Deriver::Context.new(root)
        keys.map { |key| session_row(context, key, dir) }
      end

      def wanted?(key, filter)
        filter.nil? || filter.empty? || key == filter || key.split("-", 2).last == filter
      end

      def session_row(context, key, dir)
        session = Deriver::Session.new(context, key)
        Deriver::Sources.load_raw(session)
        natives = Deriver::Sources.discover(context, session.harness, session.session_id, Deriver::Sources.main_path(session))
        return base(context, key, NO_REFERENCE) if natives.empty? || Deriver::Spool.held?(session, natives[Ids::MAIN_AGENT])

        version = nil
        native = natives.keys.sort.to_h do |agent|
          batch = context.seam(:ingest_claude).read(natives[agent]["path"], session_id: session.session_id, agent_key: agent)
          version ||= batch.harness_version
          [agent, batch]
        end
        view = Ingest::ClaudeBodies.view(dir, session_id: session.session_id, evidence: Ingest::ClaudeBodies::Evidence.new(session.raw))
        return base(context, key, NO_BODIES) if view.mine.zero?

        compare(context, key, session, native, view, version)
      end

      def base(context, key, verdict)
        { "session_key" => key, "scope_root" => context.root, "verdict" => verdict, "agents" => [], "causes" => [] }
      end

      def compare(context, key, session, native, view, version)
        bodies = view.agents.to_h do |agent, lines|
          [agent, Ingest::ClaudeBodies.batch_for(lines, session_id: session.session_id, agent_key: agent, version: version)]
        end
        agents = (native.keys | bodies.keys).sort.map { |agent| agent_row(session, agent, native[agent], bodies[agent]) }
        causes = agents.flat_map { |row| row["causes"].map { |cause| cause.merge("agent_key" => row["agent_key"]) } }
        causes += view.gaps.map { |gap| { "cause" => gap["cause"], "where" => gap["suffix"], "count" => gap["count"], "agent_key" => nil } }
        causes << { "cause" => "requests_held_back", "count" => view.held_back.size, "agent_key" => nil } unless view.held_back.empty?
        base(context, key, causes.empty? ? PARITY : MISMATCH).merge(
          "harness_version" => version,
          "agents" => agents.map { |row| row.reject { |name, _| name == "causes" } }, "causes" => causes,
          "requests" => { "conversation" => view.ingested.size - view.sideband.size, "sideband" => view.sideband.size,
                          "sideband_tokens" => sideband_tokens(view.sideband) }
        )
      end

      def sideband_tokens(lines)
        lines.sum { |line| line["usage"].values_at("input_tokens", "output_tokens", "cache_read_input_tokens", "cache_creation_input_tokens").compact.sum }
      end

      def agent_row(session, agent, native, body)
        row = { "agent_key" => agent, "verdict" => PARITY, "causes" => [] }
        return row.merge("verdict" => MISMATCH, "causes" => [{ "cause" => "native_only_agent", "requests" => native.usage.size }]) unless body
        return row.merge("verdict" => MISMATCH, "causes" => [{ "cause" => "bodies_only_agent", "requests" => body.usage.size }]) unless native

        mine = visible_turns(session, agent, body)
        theirs = visible_turns(session, agent, native)
        causes = turn_causes(mine, theirs) + tool_causes(native, body) + usage_causes(native, body)
        causes << { "cause" => "reasoning_count_differs", "native" => native.reasoning["blocks"], "bodies" => body.reasoning["blocks"] } if native.reasoning["blocks"] != body.reasoning["blocks"]
        causes.concat(reasoning_text_causes(native, body))
        causes << { "cause" => "subagent_links_differ" } if links(native) != links(body)
        causes << { "cause" => "title_differs" } if agent == Ids::MAIN_AGENT && native.title != body.title
        causes << { "cause" => "agent_id_differs" } if native.agent_id != body.agent_id
        causes.concat(timestamp_causes(native, body))
        causes.concat(source_causes(native, body))
        row.merge("verdict" => causes.empty? ? PARITY : MISMATCH, "causes" => causes,
                  "turns" => { "bodies" => mine.size, "native" => theirs.size },
                  "requests" => { "bodies" => body.usage.size, "native" => native.usage.size }, "tools" => { "bodies" => body.tool_calls.size, "native" => native.tool_calls.size })
      end

      def reasoning_text_causes(native, body)
        theirs = reasoning_texts(native)
        mine = reasoning_texts(body)
        return [] unless theirs > mine

        [{ "cause" => REASONING_TEXT, "native_blocks_with_text" => theirs, "bodies_blocks_with_text" => mine, "blocks" => native.reasoning["blocks"] }]
      end

      def reasoning_texts(batch)
        batch.entries.count { |entry| entry["kind"] == "reasoning" && entry["content"].is_a?(String) && !entry["content"].strip.empty? }
      end

      def timestamp_causes(native, body)
        return [] unless native.exchanges.size == body.exchanges.size

        skews = native.exchanges.zip(body.exchanges).filter_map do |left, right|
          next if left["ts"] == right["ts"] || left["ts"].nil? || right["ts"].nil?

          ((Time.iso8601(left["ts"]).to_r - Time.iso8601(right["ts"]).to_r).abs * 1000).to_i
        end
        return [] if skews.empty?

        [{ "cause" => TIMESTAMPS, "count" => skews.size, "max_ms" => skews.max }]
      end

      def source_causes(native, body)
        mine = sources(body)
        theirs = sources(native)
        differing = (mine.keys | theirs.keys).reject { |key| mine[key] == theirs[key] }
        return [] if differing.empty?

        [{ "cause" => "exchange_source_differs", "count" => differing.size,
           "exchanges" => differing.map { |key| { "role" => key[0], "digest" => key[1], "source" => key[2], "native" => theirs[key].to_i, "bodies" => mine[key].to_i } } }]
      end

      def sources(batch)
        batch.exchanges.select { |exchange| exchange["kind"] == "text" }.map do |exchange|
          [exchange["role"], digest(exchange["text"].to_s.gsub(/\s+/, " ").strip), exchange["source"]]
        end.tally
      end

      def turn_causes(mine, theirs)
        return [] if mine == theirs
        return [trailing(theirs, mine.size)] if mine.size < theirs.size && theirs.first(mine.size) == mine

        [Turns.difference(mine, theirs).then do |cause|
          cause.reject { |name, _| %w[specstory tellem].include?(name) }.merge("bodies" => cause["tellem"], "native" => cause["specstory"])
        end]
      end

      def visible_turns(session, agent, batch)
        turns = Turns.parse(render(session, agent, batch)).reject { |turn| turn["queued"] || turn["thinking"] || turn["sidechain"] }
        turns.map { |turn| Turns.key(turn) }
      end

      def trailing(turns, from)
        { "cause" => "native_only_trailing_turns", "count" => turns.size - from, "first_index" => from,
          "native" => turns.drop(from).map { |key| { "role" => key[0], "digest" => key[1], "tool" => key[2] } } }
      end

      def render(session, agent, batch)
        Transcript::Markdown.render(session: { "harness" => HARNESS, "session_id" => session.session_id, "started_at" => batch.started_at, "title" => batch.title },
                                    agent: { "agent_key" => agent, "agent_id" => batch.agent_id }, exchanges: batch.exchanges)
      end

      def tool_causes(native, body)
        mine = tools(body)
        theirs = tools(native)
        causes = []
        (theirs.keys - mine.keys).each { |id| causes << { "cause" => "native_only_tool", "tool_use_id" => id, "tool" => theirs[id]["name"] } }
        (mine.keys - theirs.keys).each { |id| causes << { "cause" => "bodies_only_tool", "tool_use_id" => id, "tool" => mine[id]["name"] } }
        (mine.keys & theirs.keys).each { |id| causes.concat(tool_field_causes(id, mine[id], theirs[id])) }
        causes << { "cause" => "tool_order_differs" } if causes.empty? && mine.keys != theirs.keys
        causes
      end

      def tool_field_causes(id, mine, theirs)
        return [{ "cause" => TERMINAL_RESULT, "tool_use_id" => id, "tool" => theirs["name"] }] if mine["result"].nil? && mine["answered"] == false && theirs["answered"]

        %w[name input result is_error].filter_map do |field|
          next if mine[field] == theirs[field]

          { "cause" => cause_name(field, mine, theirs), "tool_use_id" => id, "tool" => theirs["name"], "bodies" => mine[field], "native" => theirs[field] }
        end
      end

      def cause_name(field, mine, theirs)
        field == "input" && subset?(mine["raw_input"], theirs["raw_input"]) ? ENRICHED_INPUT : "tool_#{field}_differs"
      end

      def subset?(small, large)
        small.is_a?(Hash) && large.is_a?(Hash) && small.all? { |key, value| large[key] == value }
      end

      def tools(batch)
        batch.exchanges.each_with_object({}) do |exchange, out|
          tool = exchange["tool"]
          next unless tool

          out[tool["id"]] = { "name" => tool["name"], "input" => digest(tool["input"]), "result" => digest(tool["result"]), "is_error" => tool["is_error"] == true,
                              "answered" => !tool["result_at"].nil?, "raw_input" => tool["input"] }
        end
      end

      def digest(value)
        return nil if value.nil?

        Ids.sha256(value.is_a?(String) ? value : JSON.generate(value))[0, DIGEST_HEX]
      end

      def usage_causes(native, body)
        mine = body.usage.to_h { |entry| [entry["request_key"], entry] }
        theirs = native.usage.to_h { |entry| [entry["request_key"], entry] }
        causes = []
        (theirs.keys - mine.keys).each { |key| causes << { "cause" => "native_only_request", "request_key" => key } }
        (mine.keys - theirs.keys).each { |key| causes << { "cause" => "bodies_only_request", "request_key" => key } }
        (mine.keys & theirs.keys).each do |key|
          USAGE_FIELDS.each do |field|
            next if mine[key][field] == theirs[key][field]

            causes << { "cause" => "usage_field_differs", "request_key" => key, "field" => field, "bodies" => mine[key][field], "native" => theirs[key][field] }
          end
        end
        causes
      end

      def links(batch)
        batch.subagents.map { |link| [link["tool_use_id"], link["agent_id"]] }.sort
      end

      def text(report)
        return "body spool refused (#{report['spool_unsafe']}): #{report['spool']}" if report["spool_unsafe"]

        rows = report["sessions"].flat_map do |entry|
          next [[entry["session_key"], "-", entry["verdict"], "-", "-", "-", "-"]] if entry["agents"].empty?

          entry["agents"].map do |agent|
            [entry["session_key"], agent["agent_key"], agent["verdict"], pair(agent["turns"]), pair(agent["requests"]), pair(agent["tools"]),
             Reports::Text.cell(entry["causes"].select { |cause| cause["agent_key"] == agent["agent_key"] }.map { |cause| cause["cause"] }.uniq)]
          end
        end
        loose = report["sessions"].flat_map { |entry| entry["causes"].select { |cause| cause["agent_key"].nil? }.map { |cause| "#{entry['session_key']}: #{cause['cause']} #{cause['where']} (#{cause['count']})" } }
        sideband = report["sessions"].filter_map { |entry| entry["requests"] && "#{entry['session_key']} #{entry['requests']['sideband']} requests, #{entry['requests']['sideband_tokens']} tokens" }
        criteria = report["criteria"]
        [Reports::Text.table(%w[SESSION AGENT VERDICT TURNS REQUESTS TOOLS CAUSES], rows),
         "not tied to one agent: #{loose.empty? ? 'none' : loose.join('; ')}",
         "sideband requests native transcripts never hold: #{sideband.empty? ? 'none' : sideband.join('; ')}",
         "body parity #{criteria['met'] ? 'met' : 'unmet'}: #{criteria['passing']} of #{criteria['considered']} sessions",
         *recorded_text(report["recorded"])].join("\n")
      end

      def recorded_text(rows)
        return [] if rows.nil? || rows.empty?

        ["recorded at rehearse: #{rows.size} sessions"] + rows.map do |row|
          "  #{row['session_key']} at #{row['harness_version']}: #{row['verdict']}; #{row['causes'].map { |name, count| "#{name} #{count}" }.join(', ')}"
        end
      end

      def pair(counts)
        counts ? "#{counts['bodies']}/#{counts['native']}" : "-"
      end
    end
  end
end
