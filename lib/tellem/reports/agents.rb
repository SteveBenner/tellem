# frozen_string_literal: true

require_relative "../errors"
require_relative "../ids"
require_relative "../record/pointers"
require_relative "records"
require_relative "scopes"

module Tellem
  module Reports
    module Agents
      USAGE = "AGENT is SESSION_KEY, SESSION_KEY/AGENT_KEY, or a subagent id"
      FIELDS = %w[agent_type model effort isolation parent_agent_key spawn_tool_use_id evidence home_place_id].freeze

      Found = Struct.new(:data, :session_key, :agent_key, :gone, keyword_init: true)

      module_function

      def loader
        cache = {}
        ->(scope) { cache[scope["scope_id"]] ||= Records.load(scope) }
      end

      def locate(scopes, spec, load)
        session_key, agent_key = spec.split("/", 2)
        if agent_key || Ids.valid_session_key?(spec)
          agent_key ||= Ids::MAIN_AGENT
          raise UsageError.new("#{spec} is not a valid agent; #{USAGE}") unless Ids.valid_session_key?(session_key) && Ids.valid_agent_key?(agent_key)

          found = in_session(scopes, session_key, agent_key, load)
          return found if found
        else
          key = Ids.agent_key(spec)
          raise UsageError.new("#{spec} is not a valid agent; #{USAGE}") unless key && key == spec

          matches = Scopes.live(scopes).flat_map do |scope|
            data = load.call(scope)
            data.session_keys.select { |session| agents(data, session).key?(key) }.map { |session| Found.new(data: data, session_key: session, agent_key: key, gone: nil) }
          end
          return matches.first if matches.size == 1
          if matches.size > 1
            raise OperationalFailure.new("#{spec} matches #{matches.size} agents",
                                         next_command: "tellem where SESSION_KEY/#{spec}")
          end
        end
        raise OperationalFailure.new("no agent #{spec} in #{Scopes.live(scopes).map { |scope| scope['root'] }.join(', ')}",
                                     next_command: "tellem sessions --all")
      end

      def in_session(scopes, session_key, agent_key, load)
        live = Scopes.live(scopes)
        live.each do |scope|
          data = load.call(scope)
          return Found.new(data: data, session_key: session_key, agent_key: agent_key, gone: nil) if data.session_keys.include?(session_key)
        end
        live.each do |scope|
          pointer = Record::Pointers.read(scope["root"], session_key)
          next unless pointer

          home = Scopes.pointer_home(pointer)
          return Found.new(data: nil, session_key: session_key, agent_key: agent_key, gone: Record::Pointers.resolve(pointer)) unless home

          return Found.new(data: load.call(home), session_key: session_key, agent_key: agent_key, gone: nil)
        end
        nil
      end

      def agents(data, session_key)
        out = {}
        records = data.records.select { |record| record["session_key"] == session_key }
        records.each { |record| out[record["agent_key"]] ||= blank(record["agent_key"]) if record["agent_key"].is_a?(String) }
        records.select { |record| record["kind"] == "agent" }.sort_by { |record| Records.sort_key(record) }.each do |record|
          body = record["body"] || {}
          out[record["agent_key"]] = out.fetch(record["agent_key"]).merge(body.slice(*FIELDS))
        end
        out
      end

      def blank(agent_key)
        { "agent_key" => agent_key }.merge(FIELDS.to_h { |field| [field, nil] })
      end

      def children(agents)
        map = Hash.new { |hash, key| hash[key] = [] }
        agents.each_value do |agent|
          parent = agent["parent_agent_key"]
          map[parent] << agent["agent_key"] if parent && agents.key?(parent) && parent != agent["agent_key"]
        end
        map.each_value(&:sort!)
        map
      end

      def roots(agents)
        agents.values.reject { |agent| agent["parent_agent_key"] && agents.key?(agent["parent_agent_key"]) && agent["parent_agent_key"] != agent["agent_key"] }
              .map { |agent| agent["agent_key"] }.sort_by { |key| [key == Ids::MAIN_AGENT ? 0 : 1, key] }
      end

      def descendants(agents, agent_key)
        kids = children(agents)
        order = []
        queue = [agent_key]
        seen = {}
        until queue.empty?
          key = queue.shift
          next if seen[key]

          seen[key] = true
          order << key
          queue.concat(kids[key])
        end
        order
      end

      def session(data, session_key)
        record = data.records.select { |item| item["kind"] == "session" && item["session_key"] == session_key }.max_by { |item| Records.sort_key(item) }
        body = record ? record["body"] || {} : {}
        { "session_key" => session_key, "scope_id" => data.scope["scope_id"], "root" => data.scope["root"],
          "harness" => body["harness"] || session_key.split("-", 2).first, "harness_version" => body["harness_version"],
          "started_at" => body["started_at"], "ended_at" => ended_at(data, session_key) || body["ended_at"],
          "home" => Records.place(data.places, body["home_place_id"]) }
      end

      def ended_at(data, session_key)
        data.for_agent("lifecycle", session_key, Ids::MAIN_AGENT).select { |record| record.dig("body", "state") == "stopped" }
            .map { |record| record["ts"].to_s }.max
      end
    end
  end
end
