# frozen_string_literal: true

require_relative "../record/pointers"
require_relative "agents"
require_relative "records"
require_relative "scopes"
require_relative "tasks"
require_relative "text"

module Tellem
  module Reports
    module Sessions
      module_function

      def run(scopes)
        load = Agents.loader
        rows = Scopes.live(scopes).flat_map do |scope|
          data = load.call(scope)
          homed = data.session_keys.map { |key| homed(data, key) }
          pointed = Record::Pointers.each(scope["root"]).map { |pointer| pointed(scope, pointer) }
          homed + pointed
        end
        breakdown = Tasks.session_breakdown(scopes)
        rows.each { |row| row["tasks"] = row["relation"] == "home" ? Tasks.cells(breakdown, row["session_key"]) : [] } if breakdown
        rows.sort_by { |row| [row["started_at"] || row["first_at"] || "", row["session_key"], row["relation"], row["scope_id"]] }
      end

      def homed(data, key)
        session = Agents.session(data, key)
        agents = Agents.agents(data, key).keys.sort
        session.merge("relation" => "home", "gone" => false, "agents" => agents, "home_root" => data.scope["root"],
                      "home_scope_id" => data.scope["scope_id"], "first_at" => nil, "last_at" => nil, "kinds" => nil)
      end

      def pointed(scope, pointer)
        resolved = Record::Pointers.resolve(pointer)
        { "session_key" => pointer["session_key"], "scope_id" => scope["scope_id"], "root" => scope["root"],
          "harness" => pointer["session_key"].to_s.split("-", 2).first, "harness_version" => nil, "started_at" => nil,
          "ended_at" => nil, "home" => nil, "relation" => "pointer", "gone" => resolved["gone"], "agents" => Array(pointer["agents"]),
          "home_root" => pointer["home_root"], "home_scope_id" => pointer["home_scope_id"], "first_at" => pointer["first_at"],
          "last_at" => pointer["last_at"], "kinds" => Array(pointer["kinds"]) }
      end

      def text(rows)
        headers = %w[session relation started ended home agents gone]
        withtasks = rows.any? { |row| row.key?("tasks") }
        headers << "tasks" if withtasks
        table = rows.map do |row|
          cells = [row["session_key"], row["relation"], Text.cell(row["started_at"] || row["first_at"]), Text.cell(row["ended_at"] || row["last_at"]),
                   Text.cell(row["home_root"]), Text.cell(row["agents"]), row["gone"] ? "gone" : "-"]
          cells << Tasks.cell_text(row["tasks"]) if withtasks
          cells
        end
        Text.table(headers, table)
      end
    end
  end
end
