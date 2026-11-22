# frozen_string_literal: true

require_relative "../ids"
require_relative "../record/fs"
require_relative "../deriver/session"

module Tellem
  module Import
    module Records
      module_function

      def session(session, candidate, started)
        return unless session.of("session").empty?

        home = session.local_place(session.root, agent_key: Ids::MAIN_AGENT, ts: started)
        session.home[Ids::MAIN_AGENT] ||= home if home
        session.add("session", agent_key: Ids::MAIN_AGENT, ts: started, body: {
                      "harness" => candidate.harness, "harness_version" => nil, "host" => Record::FS.host,
                      "home_place_id" => home && home["place_id"], "started_at" => started, "ended_at" => nil
                    })
      end
    end
  end
end
