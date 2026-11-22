# frozen_string_literal: true

require_relative "agents"
require_relative "records"
require_relative "text"

module Tellem
  module Reports
    module Where
      VERBS = %w[lives_in stands_in works_in shells_out_from reaches spawned_at].freeze

      module_function

      def run(scopes, spec, descendants: false)
        load = Agents.loader
        found = Agents.locate(scopes, spec, load)
        return { "agent" => spec, "gone" => true, "pointer" => found.gone, "agents" => [] } if found.gone

        data = found.data
        agents = Agents.agents(data, found.session_key)
        keys = descendants ? Agents.descendants(agents, found.agent_key) : [found.agent_key]
        { "agent" => "#{found.session_key}/#{found.agent_key}", "gone" => false,
          "agents" => keys.map { |key| agent(data, found.session_key, key, agents[key]) } }
      end

      def agent(data, session_key, agent_key, info)
        places = data.places
        stands = data.for_agent("stands_in", session_key, agent_key).sort_by { |record| [record.dig("body", "from").to_s, record["id"]] }
        {
          "session_key" => session_key,
          "agent_key" => agent_key,
          "parent_agent_key" => info && info["parent_agent_key"],
          "lives_in" => info && info["home_place_id"] ? [Records.place(places, info["home_place_id"])] : [],
          "stands_in" => stands.map { |record| Records.place(places, record.dig("body", "place_id")).merge(record["body"].slice("from", "to")) },
          "works_in" => grouped(data.for_agent("works_in", session_key, agent_key), places, { "ops" => "op", "tools" => "tool" }),
          "shells_out_from" => grouped(data.for_agent("shells_out", session_key, agent_key), places, { "programs" => "program" }),
          "reaches" => grouped(data.for_agent("reaches", session_key, agent_key), places, { "via_programs" => "via_program", "evidence" => "evidence" }),
          "spawned_at" => spawned_at(data, session_key, agent_key)
        }
      end

      def grouped(records, places, lists)
        records.group_by { |record| record.dig("body", "place_id") }.sort_by { |place_id, _| place_id.to_s }.map do |place_id, group|
          out = Records.place(places, place_id) || { "place_id" => nil, "known" => false }
          lists.each { |name, field| out[name] = group.filter_map { |record| record.dig("body", field) }.uniq.sort_by(&:to_s) }
          times = group.map { |record| record["ts"].to_s }.sort
          out.merge("count" => group.size, "first_at" => times.first, "last_at" => times.last)
        end
      end

      def spawned_at(data, session_key, agent_key)
        data.of_kind("spawn").select { |record| record["session_key"] == session_key && record.dig("body", "child_agent_key") == agent_key }
            .sort_by { |record| Records.sort_key(record) }.map do |record|
          body = record["body"]
          (Records.place(data.places, body["spawned_at_place_id"]) || { "place_id" => nil, "known" => false })
            .merge("at" => record["ts"], "parent_agent_key" => body["parent_agent_key"], "spawn_tool_use_id" => body["spawn_tool_use_id"],
                   "requested_type" => body["requested_type"], "isolation" => body["isolation"])
        end
      end

      def text(report)
        if report["gone"]
          pointer = report["pointer"]
          return "#{report['agent']}: session gone (home #{pointer['home_root']}, #{pointer['first_at']} .. #{pointer['last_at']})"
        end

        report["agents"].flat_map do |agent|
          ["#{agent['session_key']}/#{agent['agent_key']}"] + VERBS.flat_map do |verb|
            entries = agent[verb]
            next ["  #{verb}: -"] if entries.empty?

            entries.map { |entry| "  #{verb}: #{Text.place(entry)}#{extra(verb, entry)}" }
          end
        end.join("\n")
      end

      def extra(verb, entry)
        case verb
        when "stands_in" then "  #{entry['from'] || '-'} .. #{entry['to'] || '-'}"
        when "works_in" then "  #{Text.cell(entry['ops'])} via #{Text.cell(entry['tools'])} x#{entry['count']}"
        when "shells_out_from" then "  #{Text.cell(entry['programs'])} x#{entry['count']}"
        when "reaches" then "  via #{Text.cell(entry['via_programs'])} (#{Text.cell(entry['evidence'])}) x#{entry['count']}"
        when "spawned_at" then "  at #{entry['at']} by #{entry['parent_agent_key'] || '-'}"
        else ""
        end
      end
    end
  end
end
