# frozen_string_literal: true

require "time"
require_relative "../errors"
require_relative "../ids"
require_relative "agents"
require_relative "records"
require_relative "scopes"

module Tellem
  module Reports
    module Messages
      CHANNELS = %w[spawn send handback receive].freeze
      WINDOW_S = 600
      LINE_CHARS = 100
      ROW_FIELDS = %w[message_key channel from_agent_key to_agent_key from_address to_address from_name summary head bytes digest
                      source_id delivered_at is_error].freeze

      module_function

      def run(scopes, session: nil, agent: nil, channel: nil, since: nil)
        raise UsageError.new("#{session} is not a session key") if session && !Ids.valid_session_key?(session)
        raise UsageError.new("channel must be one of #{CHANNELS.join(', ')}, not #{channel}") if channel && !CHANNELS.include?(channel)

        load = Agents.loader
        rows = joined(all_rows(scopes, load))
        if session
          found = Agents.in_session(scopes, session, Ids::MAIN_AGENT, load)
          raise OperationalFailure.new("no session #{session} in the covered scopes", next_command: "tellem sessions --all") unless found
          return [] if found.gone

          rows = rows.select { |row| row["session_key"] == session }
        end
        rows = rows.select { |row| [row["agent_key"], row["from_agent_key"], row["to_agent_key"]].include?(agent) } if agent
        rows = rows.select { |row| row["channel"] == channel } if channel
        rows = rows.select { |row| row["ts"].to_s >= since } if since
        rows
      end

      def all_rows(scopes, load)
        seen = {}
        Scopes.live(scopes).flat_map do |scope|
          load.call(scope).of_kind("message").filter_map do |record|
            next if seen[record["id"]]

            seen[record["id"]] = true
            row(record)
          end
        end.sort_by { |item| [item["ts"].to_s, item["session_key"], item["agent_key"], item["channel"], item["message_key"].to_s] }
      end

      def row(record)
        body = record["body"] || {}
        out = { "ts" => record["ts"], "session_key" => record["session_key"], "agent_key" => record["agent_key"] }
        ROW_FIELDS.each { |field| out[field] = body[field] }
        out.merge("join" => nil, "peer" => nil)
      end

      def cross?(row)
        case row["channel"]
        when "send" then row["to_agent_key"].nil? && !row["to_address"].nil?
        when "receive" then row["from_agent_key"].nil? && !row["from_address"].nil?
        else false
        end
      end

      def joined(rows)
        receives = rows.select { |row| row["channel"] == "receive" && cross?(row) && row["digest"] }.group_by { |row| row["digest"] }
        taken = {}
        rows.each do |row|
          next unless cross?(row)

          row["join"] ||= "unjoined"
          next unless row["channel"] == "send" && row["digest"]

          epoch = Time.iso8601(row["ts"]).to_f
          match = receives.fetch(row["digest"], []).find { |candidate| !taken[candidate.object_id] && within?(epoch, candidate["ts"]) }
          next unless match

          taken[match.object_id] = true
          row["join"] = "joined"
          row["peer"] = peer(match)
          match["join"] = "joined"
          match["peer"] = peer(row)
        end
        rows
      end

      def within?(sent, received_ts)
        delta = Time.iso8601(received_ts).to_f - sent
        delta >= 0 && delta <= WINDOW_S
      end

      def peer(row)
        { "session_key" => row["session_key"], "agent_key" => row["agent_key"], "ts" => row["ts"], "channel" => row["channel"] }
      end

      def text(rows)
        return "(no messages)" if rows.empty?

        rows.map do |row|
          detail = (row["summary"] || row["head"] || "").gsub(/\s+/, " ").strip
          detail = "#{detail[0, LINE_CHARS - 3]}..." if detail.length > LINE_CHARS
          [row["ts"], row["channel"], side(row, "from"), "->", side(row, "to"), "#{row['bytes'] || '-'}B", detail].join("  ").rstrip
        end.join("\n")
      end

      def side(row, direction)
        agent = row["#{direction}_agent_key"]
        return agent if agent

        address = row["#{direction}_address"]
        return "-" unless address
        return address unless other_side?(row, direction)

        peer = row["peer"]
        return "#{address} (#{peer['session_key']}/#{peer['agent_key']})" if peer

        row["join"] == "unjoined" ? "#{address} (unjoined)" : address
      end

      def other_side?(row, direction)
        (row["channel"] == "send" && direction == "to") || (row["channel"] == "receive" && direction == "from")
      end
    end
  end
end
