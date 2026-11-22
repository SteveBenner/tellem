# frozen_string_literal: true

require_relative "../entries/store"

module Tellem
  module Deriver
    module Entries
      FLAG = "transcripts.entries"

      module_function

      def derive(session)
        return unless session.context.flag?(FLAG)

        session.batches.keys.sort.each do |agent|
          Tellem::Entries::Store.append(session.root, session.key, agent, session.batches[agent])
        end
      end
    end
  end
end
