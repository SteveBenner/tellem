# frozen_string_literal: true

require_relative "../errors"
require_relative "../record/exclude"
require_relative "../record/fs"
require_relative "../record/pointers"
require_relative "../record/registry"
require_relative "../record/scope"

module Tellem
  module Reports
    module Scopes
      module_function

      def resolve(scope: nil, all: false, cwd: Dir.pwd)
        raise UsageError.new("--scope and --all exclude each other") if scope && all

        roots = if all
                  open_roots + [Record::Scope.locate(cwd)]
                else
                  [root_for(scope || cwd)]
                end
        roots.uniq.map { |root| entry(root) }.uniq { |item| item["scope_id"] }.sort_by { |item| [item["scope_id"], item["root"]] }
      end

      def open_roots
        user = Record::Scope.user_root
        Record::Registry.entries.map { |entry| entry["root"].to_s }.reject { |root| root != user && Record::Exclude.covers?(root) }
      end

      def root_for(path)
        raise UsageError.new("scope path #{path} does not exist") unless File.exist?(path)

        Record::Scope.locate(path)
      end

      def entry(root)
        present = present?(root)
        scope_id = present ? descriptor_id(root) : Record::Scope.scope_id(root)
        { "scope_id" => scope_id, "root" => root, "kind" => Record::Scope.kind(root), "gone" => !present }
      end

      def present?(root)
        dir = Record::Scope.dir(root)
        stat = Record::FS.lstat(dir)
        stat&.directory? && Record::FS.lstat(File.join(dir, "scope.json"))&.file? ? true : false
      rescue Errno::EACCES, Errno::EPERM
        true
      end

      def descriptor_id(root)
        Record::Scope.descriptor(root)["scope_id"].to_s
      rescue StandardError
        Record::Scope.scope_id(root)
      end

      def live(scopes)
        scopes.reject { |item| item["gone"] }
      end

      def pointer_home(pointer)
        root = pointer["home_root"].to_s
        return nil if root.empty? || Record::Pointers.gone?(pointer)

        entry(root)
      end

      def summary(scopes)
        scopes.map { |item| item.slice("scope_id", "root", "kind", "gone") }
      end
    end
  end
end
