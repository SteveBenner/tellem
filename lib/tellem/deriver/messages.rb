# frozen_string_literal: true

require "time"
require_relative "../ids"
require_relative "../redact"
require_relative "../ingest/support"
require_relative "agents"

module Tellem
  module Deriver
    module Messages
      MAIN = Ids::MAIN_AGENT
      HEAD_BYTES = 200
      WINDOW_S = 600
      SPAWN_KEYS = %w[prompt message description].freeze
      SEND_KEYS = %w[message items].freeze
      SEND_TOOLS = { "claude" => %w[SendMessage], "codex" => %w[send_input send_message] }.freeze
      TARGET_KEYS = { "claude" => %w[to], "codex" => %w[id agent_id target] }.freeze

      module_function

      def derive(session)
        children = session.links.to_h { |child, link| [link["tool_use_id"], child] }
        refs = entry_refs(session)
        session.calls.keys.sort.each do |id|
          call = session.calls[id]
          name = call["tool"]["name"]
          if session.context.spawn_tools(session.harness).include?(name)
            spawn(session, id, call, children, refs)
            handback(session, id, call, children, refs)
          elsif SEND_TOOLS.fetch(session.harness, []).include?(name)
            send_call(session, id, call, refs)
          end
        end
        receives(session)
      end

      def entry_refs(session)
        session.batches.to_h do |agent, batch|
          [agent, batch.entries.each_with_object({}) { |entry, out| out[[entry["kind"], entry["call_id"]]] ||= entry["ref"] if entry["call_id"] }]
        end
      end

      def spawn(session, id, call, children, refs)
        tool = call["tool"]
        ts = call["ts"] || tool["result_at"]
        return unless ts.is_a?(String) && tool["result_at"].is_a?(String)

        child = children[id]
        text, bytes = field(session, call, SPAWN_KEYS)
        add(session, call["agent"], ts, text, bytes,
            "message_key" => id, "channel" => "spawn", "from_agent_key" => call["agent"], "to_agent_key" => child,
            "to_address" => child ? nil : Agents.requested_type(call), "source_id" => refs.dig(call["agent"], ["action", id]) || id,
            "delivered_at" => tool["result_at"])
      end

      def send_call(session, id, call, refs)
        tool = call["tool"]
        return unless call["ts"].is_a?(String)

        target = target(session, tool)
        key = target.is_a?(String) ? agent_for(session, target) : nil
        text, bytes = field(session, call, SEND_KEYS)
        summary = tool["withheld"] != true && tool["input"].is_a?(Hash) && tool["input"]["summary"].is_a?(String) ? Redact.text(tool["input"]["summary"]) : nil
        add(session, call["agent"], call["ts"], text, bytes,
            "message_key" => id, "channel" => "send", "from_agent_key" => call["agent"], "to_agent_key" => key,
            "to_address" => key || !target.is_a?(String) ? nil : target, "summary" => summary,
            "source_id" => refs.dig(call["agent"], ["action", id]) || id)
      end

      def handback(session, id, call, children, refs)
        tool = call["tool"]
        return unless tool["result_at"].is_a?(String)

        batch = session.batches[call["agent"]]
        return if batch&.async_results&.key?(id)

        child = children[id]
        result = tool["result"]
        text = tool["withheld"] != true && result.is_a?(String) ? result : nil
        bytes = batch&.result_bytes&.fetch(id, nil) || (result.is_a?(Hash) ? result["content_omitted"] : nil)
        add(session, child || call["agent"], tool["result_at"], text, bytes,
            "message_key" => "#{id}:handback", "channel" => "handback", "from_agent_key" => child, "to_agent_key" => call["agent"],
            "source_id" => refs.dig(call["agent"], ["output", id]) || id, "is_error" => tool["is_error"])
      end

      def target(session, tool)
        input = tool["input"]
        return nil unless input.is_a?(Hash) && tool["withheld"] != true

        TARGET_KEYS.fetch(session.harness, []).filter_map { |key| input[key] if input[key].is_a?(String) && !input[key].empty? }.first
      end

      def agent_for(session, target)
        return MAIN if target == MAIN

        key = Ids.agent_key(target)
        key && session.agent_keys.include?(key) ? key : nil
      end

      def field(session, call, keys)
        tool = call["tool"]
        batch = session.batches[call["agent"]]
        sizes = batch&.input_bytes&.fetch(tool["id"], nil) || {}
        bytes = keys.filter_map { |key| sizes[key] }.first
        return [nil, bytes] if tool["withheld"] == true || !tool["input"].is_a?(Hash)

        key = keys.find { |name| Ingest::Support.message_field(name, tool["input"][name]) }
        [key && Ingest::Support.message_field(key, tool["input"][key]), key ? sizes[key] : bytes]
      end

      def receives(session)
        session.batches.keys.sort.each do |agent|
          items = Array(session.batches[agent].received)
          next if items.empty?

          if session.harness == "codex"
            next if agent == MAIN

            items.each { |item| receive(session, agent, item, session.links.dig(agent, "parent"), nil) }
          else
            clusters(items).each { |item| receive(session, agent, item, nil, item["from"]) }
          end
        end
      end

      def clusters(items)
        prepared = items.each_with_index.map do |item, order|
          item.merge("digest" => Ids.sha256(Redact.text(item["text"])), "epoch" => Time.iso8601(item["ts"]).to_f, "order" => order)
        end
        prepared.group_by { |item| item["digest"] }.values.flat_map do |list|
          list.sort_by { |item| [item["epoch"], item["order"]] }.each_with_object([]) do |item, out|
            out << item unless out.last && item["epoch"] - out.last["epoch"] <= WINDOW_S
          end
        end.sort_by { |item| [item["epoch"], item["order"]] }
      end

      def receive(session, agent, item, parent, from)
        sender = parent || (from.is_a?(String) && !from.empty? ? agent_for(session, from) : nil)
        sender = nil if sender == agent
        add(session, agent, item["ts"], item["text"], item["text"].bytesize,
            "message_key" => item["ref"], "channel" => "receive", "from_agent_key" => sender, "to_agent_key" => agent,
            "from_address" => from, "from_name" => item["from_name"], "source_id" => item["ref"])
      end

      def add(session, agent, ts, text, bytes, fields)
        redacted = text && Redact.text(text)
        body = { "message_key" => nil, "channel" => nil, "from_agent_key" => nil, "to_agent_key" => nil, "from_address" => nil,
                 "to_address" => nil, "from_name" => nil, "summary" => nil, "head" => redacted && head(redacted), "bytes" => bytes,
                 "digest" => redacted && Ids.sha256(redacted), "source_id" => nil, "delivered_at" => nil, "is_error" => nil }
        session.add("message", agent_key: agent, ts: ts, body: body.merge(fields))
      end

      def head(text)
        cut = text.byteslice(0, HEAD_BYTES)
        cut = cut.byteslice(0, cut.bytesize - 1) until cut.valid_encoding?
        cut
      end
    end
  end
end
