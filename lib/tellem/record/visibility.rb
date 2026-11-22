# frozen_string_literal: true

require_relative "../errors"
require_relative "../config/resolver"
require_relative "fs"
require_relative "schemas"
require_relative "scope"

module Tellem
  module Record
    module Visibility
      KEY = "visibility"
      PUBLIC = "public"
      PRIVATE = "private"
      IGNORE = ".gitignore"
      HISTORY = File.join(".specstory", "history")
      VOLATILE = %w[
        derive.lock
        derive.dirty
        derive.cursor.json
        mirror.sqlite3
        mirror.sqlite3-wal
        mirror.sqlite3-shm
        mirror.sqlite3-journal
        *.tmp
      ].freeze
      PRIVATE_IGNORE = "#{VOLATILE.join("\n")}\n"

      module_function

      def declared(root)
        return PUBLIC unless Scope.kind(root) == "repository"

        Config.get(KEY, scope: root) == PRIVATE ? PRIVATE : PUBLIC
      end

      def scope_ignore(root)
        File.join(Scope.dir(root), IGNORE)
      end

      def history_dir(root)
        File.join(root, HISTORY)
      end

      def history_ignore(root)
        File.join(history_dir(root), IGNORE)
      end

      def wanted_scope_ignore(visibility)
        visibility == PRIVATE ? PRIVATE_IGNORE : Schemas::GITIGNORE
      end

      def reconcile(root)
        root = root.to_s
        visibility = declared(root)
        changed = []
        changed << scope_ignore(root) if reconcile_scope(root, visibility)
        changed << history_ignore(root) if reconcile_history(root, visibility)
        { "root" => root, "visibility" => visibility, "changed" => changed }
      end

      def reconcile_each(roots)
        roots.map(&:to_s).uniq.sort.each_with_object([]) do |root, failures|
          reconcile(root)
        rescue StandardError => e
          failures << { "phase" => "visibility", "root" => root, "error_class" => e.class.name }
        end
      end

      def reconcile_scope(root, visibility)
        return false unless directory(Scope.dir(root))

        write_if_changed(scope_ignore(root), wanted_scope_ignore(visibility))
      end

      def reconcile_history(root, visibility)
        return false unless Scope.kind(root) == "repository"
        return false unless directory(File.join(root, ".specstory")) && directory(history_dir(root))

        path = history_ignore(root)
        current = content(path)
        if visibility == PRIVATE
          return false unless current == Schemas::GITIGNORE

          File.unlink(path)
          FS.fsync_dir(history_dir(root))
          true
        else
          return false unless current.nil?

          write_if_changed(path, Schemas::GITIGNORE)
        end
      end

      def status(root)
        root = root.to_s
        visibility = declared(root)
        drift = []
        if directory(Scope.dir(root))
          path = scope_ignore(root)
          drift << path unless content(path) == wanted_scope_ignore(visibility)
        end
        history = history_state(root)
        drift << history_ignore(root) if out_of_step?(history, visibility)
        { "root" => root, "visibility" => visibility, "history" => history, "drift" => drift }
      end

      def history_state(root)
        return "none" unless Scope.kind(root) == "repository"
        return "none" unless directory(File.join(root, ".specstory")) && directory(history_dir(root))

        current = content(history_ignore(root))
        return "absent" if current.nil?

        current == Schemas::GITIGNORE ? "tellem" : "foreign"
      end

      def out_of_step?(history, visibility)
        visibility == PRIVATE ? history == "tellem" : history == "absent"
      end

      def directory(path)
        stat = FS.lstat(path)
        raise SymlinkRefused.new("symlinked directory refused", detail: { "path" => path }) if stat&.symlink?

        stat&.directory? ? true : false
      end

      def content(path)
        FS.read(path)
      rescue Errno::ENOENT, Errno::ENOTDIR
        nil
      end

      def write_if_changed(path, bytes)
        return false if content(path) == bytes

        FS.replace(path, bytes)
        true
      end
    end
  end
end
