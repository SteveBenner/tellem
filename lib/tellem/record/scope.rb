# frozen_string_literal: true

require "json"
require_relative "../ids"
require_relative "../ports/harness_paths"
require_relative "exclude"
require_relative "fs"
require_relative "schemas"

module Tellem
  module Record
    module Scope
      KINDS = %w[repository user].freeze

      module_function

      def locate(cwd)
        start = real_existing(cwd.to_s.empty? ? "/" : cwd)
        dir = start
        loop do
          root = repository_root(dir)
          return (Exclude.covers?(root) ? user_root : root) if root

          parent = File.dirname(dir)
          break if parent == dir

          dir = parent
        end
        user_root
      end

      def user_root
        Ports::HarnessPaths.user_scope_root
      end

      def kind(root)
        root == user_root ? "user" : "repository"
      end

      def real_existing(path)
        current = File.expand_path(path)
        loop do
          return File.realpath(current) if File.directory?(current)

          parent = File.dirname(current)
          return "/" if parent == current

          current = parent
        end
      rescue SystemCallError
        "/"
      end

      def repository_root(dir)
        dotgit = File.join(dir, ".git")
        stat = FS.lstat(dotgit)
        return nil unless stat
        return (git_dir?(dotgit) ? dir : nil) if stat.directory?
        return nil unless stat.file?

        gitdir = linked_gitdir(dotgit, dir)
        return nil unless gitdir && git_dir?(gitdir)

        common = common_dir(gitdir)
        File.basename(common) == ".git" ? File.dirname(common) : dir
      end

      def git_dir?(path)
        File.file?(File.join(path, "HEAD")) &&
          (File.directory?(File.join(path, "objects")) || File.file?(File.join(path, "commondir")))
      end

      def linked_gitdir(dotgit, dir)
        line = File.read(dotgit, 4096).to_s[/\Agitdir:\s*(.+?)\s*$/, 1]
        return nil unless line

        path = File.expand_path(line, dir)
        File.directory?(path) ? File.realpath(path) : nil
      rescue SystemCallError
        nil
      end

      def common_dir(gitdir)
        pointer = File.join(gitdir, "commondir")
        return gitdir unless File.file?(pointer)

        target = File.expand_path(File.read(pointer, 4096).strip, gitdir)
        File.directory?(target) ? File.realpath(target) : gitdir
      rescue SystemCallError
        gitdir
      end

      def dir(root)
        File.join(root, Schemas::SCOPE_DIR)
      end

      def prepare(root)
        refuse_excluded!(root)
        scope = dir(root)
        stat = FS.lstat(scope)
        raise SymlinkRefused.new("symlinked scope refused", detail: { "path" => scope }) if stat&.symlink?
        return scope if stat&.directory? && FS.lexists?(File.join(scope, "scope.json"))

        create(root)
        scope
      end

      def open(root)
        prepare(root)
        descriptor(root)
      end

      def refuse_excluded!(root)
        return if root == user_root || !Exclude.covers?(root)

        raise OperationalFailure.new("scope root is excluded by scope.exclude_roots", detail: { "root" => root })
      end

      def create(root)
        refuse_excluded!(root)
        FS.mkdir_p(root) if root == user_root
        raise OperationalFailure.new("scope root does not exist", detail: { "root" => root }) unless File.directory?(root)

        scope = dir(root)
        FS.mkdir_p(scope)
        File.chmod(Schemas::DIR_MODE, scope) if FS.lstat(scope)&.directory?
        FS.write_new(File.join(scope, ".gitignore"), Schemas::GITIGNORE) unless FS.lexists?(File.join(scope, ".gitignore"))
        FS.write_new(File.join(scope, "scope.json"), "#{JSON.generate(new_descriptor(root))}\n")
        scope
      end

      def new_descriptor(root)
        host = FS.host
        {
          "schema" => Schemas::SCOPE,
          "scope_id" => Ids.scope_id(host, root),
          "kind" => kind(root),
          "root" => root,
          "host" => host,
          "created_at" => FS.rfc3339
        }
      end

      def descriptor(root)
        JSON.parse(FS.read(File.join(dir(root), "scope.json")))
      end

      def scope_id(root)
        Ids.scope_id(FS.host, root)
      end

      def session_dir(root, session_key)
        raise InvalidRecord.new("invalid session key") unless Ids.valid_session_key?(session_key)

        File.join(dir(root), "sessions", session_key)
      end

      def raw_path(root, session_key, agent_key)
        raise InvalidRecord.new("invalid agent key") unless Ids.valid_agent_key?(agent_key)

        File.join(session_dir(root, session_key), "raw", "#{agent_key}.jsonl")
      end

      def raw_dir(root, session_key)
        File.join(session_dir(root, session_key), "raw")
      end

      def derived_path(root, session_key)
        File.join(session_dir(root, session_key), "derived.jsonl")
      end

      def transcripts_dir(root, session_key)
        File.join(session_dir(root, session_key), "transcripts")
      end

      def pointer_path(root, session_key)
        raise InvalidRecord.new("invalid session key") unless Ids.valid_session_key?(session_key)

        File.join(dir(root), "pointers", "#{session_key}.json")
      end

      def pointers_dir(root) = File.join(dir(root), "pointers")
      def sessions_dir(root) = File.join(dir(root), "sessions")
      def views_dir(root) = File.join(dir(root), "views")
      def tokens_view(root) = File.join(views_dir(root), "TOKENS.jsonl")
      def prune_log(root) = File.join(dir(root), "prune.jsonl")
      def config_file(root) = File.join(dir(root), "config.yml")
      def capture_off(root) = File.join(dir(root), "capture.off")
      def lock_file(root) = File.join(dir(root), "derive.lock")
      def dirty_file(root) = File.join(dir(root), "derive.dirty")
      def cursor_file(root) = File.join(dir(root), "derive.cursor.json")
      def mirror_file(root) = File.join(dir(root), "mirror.sqlite3")

      def session_keys(root)
        Dir.children(sessions_dir(root)).select { |key| Ids.valid_session_key?(key) }.sort
      rescue SystemCallError
        []
      end
    end
  end
end
