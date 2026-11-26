# frozen_string_literal: true

module Tellem
  module Dashboard
    module Share
      module_function

      def apply(dataset)
        repos = dataset.fetch("repos").each_with_index.map do |repo, position|
          repo.merge("name" => "repository #{position + 1}", "path" => nil)
        end
        sessions = dataset.fetch("sessions").map { |session| session.merge("label" => nil, "home" => nil) }
        dataset.merge("share" => true, "repos" => repos, "sessions" => sessions)
      end
    end
  end
end
