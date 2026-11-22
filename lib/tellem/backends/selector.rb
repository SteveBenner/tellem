# frozen_string_literal: true

require_relative "../config/resolver"
require_relative "../errors"
require_relative "../ports/backend"
require_relative "../ports/harness_paths"
require_relative "../record/scope"

module Tellem
  module Backends
    class Selector < Ports::Backend
      def initialize
        super
        @adapters = {}
      end

      def foundation_default?
        false
      end

      def available?
        true
      end

      def kind
        settings(nil)[:kind]
      end

      def settings(scope_root)
        root = scope_root || Record::Scope.locate(Dir.pwd)
        {
          kind: Config.get("backend.kind", scope: root).to_s,
          location: Config.get("backend.location", scope: root).to_s,
          secret: Config.get("backend.secret", scope: root).to_s,
          scope_root: root
        }
      end

      def for(scope_root = nil)
        build(**settings(scope_root))
      end

      def build(kind:, location:, secret:, scope_root:)
        key = [kind, location, secret, scope_root]
        @adapters[key] ||= case kind
                           when "sqlite"
                             require_relative "sqlite"
                             Sqlite.new(path: sqlite_path(location, scope_root), scope_root: scope_root)
                           when "postgres"
                             require_relative "postgres"
                             Postgres.new(secret_name: secret, scope_root: scope_root)
                           else
                             Ports::Backend::None.new
                           end
      end

      def sqlite_path(location, scope_root)
        location == "user" ? Ports::HarnessPaths.user_mirror : Record::Scope.mirror_file(scope_root)
      end

      def provision(location:, install_driver:)
        self.for(nil).provision(location: location, install_driver: install_driver)
      end

      def status
        self.for(nil).status
      end

      def sync(scope_id:, observations:)
        self.for(nil).sync(scope_id: scope_id, observations: observations)
      rescue StandardError => e
        { applied: 0, skipped: 0, failures: 1, error_class: e.class.name }
      end

      def rebuild(scopes:)
        self.for(nil).rebuild(scopes: scopes)
      end

      def drop(confirm:)
        self.for(nil).drop(confirm: confirm)
      end

      def query(report:, params:)
        self.for(params && (params[:scope_root] || params["scope_root"])).query(report: report, params: params)
      end

      def feed(scope_root)
        adapter = self.for(scope_root)
        return { applied: 0, skipped: 0, skipped_reason: "no_backend" } unless adapter.respond_to?(:feed)

        adapter.feed(scope_root)
      rescue StandardError => e
        { applied: 0, skipped: 0, failures: 1, error_class: e.class.name }
      end
    end
  end
end
