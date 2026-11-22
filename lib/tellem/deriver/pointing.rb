# frozen_string_literal: true

require_relative "../errors"
require_relative "../ids"
require_relative "../record/fs"
require_relative "../record/pointers"
require_relative "../record/registry"
require_relative "../record/scope"

module Tellem
  module Deriver
    module Pointing
      KINDS = { "works_in" => "works_in", "shells_out" => "shells_out_from", "stands_in" => "stands_in" }.freeze

      module_function

      def derive(session)
        targets(session).sort.map do |target, entry|
          write(session, target, entry)
          target
        end.compact
      end

      def targets(session)
        found = {}
        located = {}
        KINDS.each do |kind, label|
          session.of(kind).each do |record|
            place = session.place_for(record["body"]["place_id"])
            path = place && place["kind"] == "local" ? place["real_path"] : nil
            next unless path.is_a?(String) && path.start_with?("/")

            target = located.fetch(path) { located[path] = Record::Scope.locate(path) }
            next if target == session.root || Record::Scope.kind(target) != "repository"

            entry = (found[target] ||= { kinds: [], agents: [], times: [] })
            entry[:kinds] << label
            entry[:agents] << record["agent_key"]
            entry[:times] << record["ts"]
          end
        end
        found
      end

      def write(session, target, entry)
        Record::Pointers.write(target, {
                                 session_key: session.key, home_scope_id: session.context.scope_id, home_root: session.root,
                                 first_at: entry[:times].min, last_at: entry[:times].max, kinds: entry[:kinds].uniq.sort,
                                 agents: entry[:agents].uniq.sort
                               })
      rescue Tellem::Error, SystemCallError => e
        session.gap("pointer_unwritable", "pointer/#{Ids.scope_id(Record::FS.host, target)}", agent_key: Ids::MAIN_AGENT,
                                                                                         ts: entry[:times].min,
                                                                                         detail: { "error_class" => e.class.name })
        nil
      end

      def register(roots)
        roots.uniq.sort.each_with_object([]) do |root, failures|
          Record::Registry.register(root)
        rescue StandardError => e
          failures << { "root" => root, "error_class" => e.class.name }
        end
      end
    end
  end
end
