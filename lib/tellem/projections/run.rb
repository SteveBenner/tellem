# frozen_string_literal: true

require_relative "../record/fs"
require_relative "../record/scope"
require_relative "../config/resolver"
require_relative "tokens"
require_relative "specstory"

module Tellem
  module Projections
    class Run
      def foundation_default?
        false
      end

      def available?
        true
      end

      def refresh(scope, force: false, check: false)
        root = scope.to_s
        summary = { "scope" => root, "skipped" => nil, "tokens" => nil, "specstory" => nil, "changed" => false }
        unless Record::FS.lstat(Record::Scope.dir(root))&.directory?
          summary["skipped"] = "no tellem scope"
          return summary
        end
        unless force || Config.get("features.views", scope: root) == true
          summary["skipped"] = "features.views off"
          return summary
        end

        summary["tokens"] = Tokens.refresh(root, check: check)
        summary["specstory"] = SpecStory.refresh(root, check: check)
        summary["changed"] = summary["tokens"]["changed"] || !summary["specstory"]["changed"].empty?
        summary
      end
    end
  end
end
