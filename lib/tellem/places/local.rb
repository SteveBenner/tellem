# frozen_string_literal: true

require_relative "../ids"
require_relative "../redact"
require_relative "../record/fs"
require_relative "../record/kinds"
require_relative "../record/formats"
require_relative "git"
require_relative "targets"

module Tellem
  module Places
    module Local
      PLACE_ENUMS = Record::Kinds.fetch("place")[:enums]
      REMOTE_KEY = /\Aremote\.(?<name>.+)\.(?<key>url|pushurl) (?<url>.*)\z/
      REMOTE_NAME = %r{\A[A-Za-z0-9][A-Za-z0-9._/-]{0,199}\z}

      module_function

      def available?
        true
      end

      def foundation_default?
        false
      end

      def resolve(path, host: Record::FS.host, base: nil, timeout_ms: Git::DEFAULT_TIMEOUT_MS, repository: true)
        absolute = absolute_path(path, base)
        return missing(path, host, "not_absolute") unless absolute
        return missing(absolute, host, "other_host") unless host == Record::FS.host

        real, tail, failure = real_split(absolute)
        return missing(absolute, host, failure) if failure

        real_path = tail.empty? ? real : File.join(real, *tail)
        attributes = {}
        repository_id = nil
        if repository
          found = lookup(lookup_dir(real), timeout_ms: timeout_ms)
          repository_id = found[:repository]&.fetch("repository_id")
          attributes["worktree_root"] = found[:toplevel] if found[:toplevel]
          attributes["repository_unknown"] = found[:cause] if found[:cause]
        end
        build(host, real_path, tail.empty? ? "full" : "partial", repository_id, attributes)
      end

      def repository(path, timeout_ms: Git::DEFAULT_TIMEOUT_MS)
        absolute = absolute_path(path, nil)
        return nil unless absolute

        real, _tail, failure = real_split(absolute)
        return nil if failure

        lookup(lookup_dir(real), timeout_ms: timeout_ms)[:repository]
      end

      def lookup(dir, timeout_ms: Git::DEFAULT_TIMEOUT_MS)
        stop_at = Git.deadline(timeout_ms)
        found = Git.run(%w[rev-parse --path-format=absolute --git-common-dir --show-toplevel], chdir: dir, until_ms: stop_at)
        if found.ok?
          lines = found.lines
        elsif found.cause == "git_failed"
          again = Git.run(%w[rev-parse --path-format=absolute --git-common-dir], chdir: dir, until_ms: stop_at)
          return {} if again.cause == "git_failed" || (again.ok? && again.lines.empty?)
          return { cause: again.cause } unless again.ok?

          lines = [again.lines.first]
        else
          return { cause: found.cause }
        end
        common = real_or_self(lines[0])
        return {} unless common

        repo = repository_record(common, dir, stop_at)
        { repository: repo, toplevel: lines[1] && safe_path(real_or_self(lines[1])) }
      end

      def repository_record(common, dir, stop_at)
        host = Record::FS.host
        common_text = safe_path(common)
        remotes, cause = remotes(dir, stop_at)
        record = {
          "repository_id" => Ids.repository_id(host, common_text),
          "host" => host,
          "common_dir" => common_text,
          "remotes" => remotes
        }
        record["remotes_unknown"] = cause if cause
        record
      end

      def remotes(dir, stop_at)
        found = Git.run(["config", "--get-regexp", '^remote\..*\.(url|pushurl)$'], chdir: dir, until_ms: stop_at)
        return [[], nil] if found.status == :failed && found.exit_code == 1
        return [nil, found.cause] unless found.ok?

        table = {}
        found.lines.each do |line|
          match = REMOTE_KEY.match(line)
          next unless match

          name = Targets.safe_text(match[:name])
          url = Targets.sanitize_url(match[:url])
          next unless name && url

          entry = (table[name] ||= { "name" => name })
          entry[match[:key] == "url" ? "url" : "push_url"] ||= url
        end
        [table.keys.sort.map { |name| table[name] }, nil]
      end

      def git_remote_lookup(timeout_ms: Git::DEFAULT_TIMEOUT_MS)
        lambda do |name, cwd|
          next nil unless cwd && File.directory?(cwd)

          stop_at = Git.deadline(timeout_ms)
          case name
          when nil then default_remote_url(cwd, stop_at)
          when :all then config_values(cwd, ["--get-regexp", '^remote\..*\.url$'], stop_at).map { |line| line.split(" ", 2)[1] }.compact
          else
            next nil unless REMOTE_NAME.match?(name.to_s) && !name.to_s.include?("..")

            config_values(cwd, ["--get", "remote.#{name}.url"], stop_at).first
          end
        end
      end

      def default_remote_url(cwd, stop_at)
        branch = Git.run(%w[symbolic-ref --quiet --short HEAD], chdir: cwd, until_ms: stop_at)
        name = nil
        if branch.ok? && (current = branch.lines.first) && REMOTE_NAME.match?(current)
          name = config_values(cwd, ["--get", "branch.#{current}.remote"], stop_at).first
        end
        name = "origin" if name.nil? || name == "."
        return nil unless REMOTE_NAME.match?(name)

        config_values(cwd, ["--get", "remote.#{name}.url"], stop_at).first
      end

      def config_values(cwd, args, stop_at)
        found = Git.run(["config", *args], chdir: cwd, until_ms: stop_at)
        found.ok? ? found.lines : []
      end

      def absolute_path(path, base)
        text = path.to_s
        return nil if text.empty? || text.include?("\0")

        unless text.start_with?("/")
          return nil unless base.is_a?(String) && base.start_with?("/")

          text = File.join(base, text)
        end
        File.expand_path(text)
      end

      def real_split(absolute)
        current = absolute
        tail = []
        loop do
          return [File.realpath(current), tail, nil]
        rescue Errno::ENOENT, Errno::ENOTDIR
          return [nil, tail, "unresolvable"] if current == "/"

          tail.unshift(File.basename(current))
          current = File.dirname(current)
        rescue Errno::EACCES
          return [nil, tail, "permission_denied"]
        rescue Errno::ELOOP
          return [nil, tail, "symlink_loop"]
        rescue SystemCallError
          return [nil, tail, "unresolvable"]
        end
      end

      def lookup_dir(real)
        File.directory?(real) ? real : File.dirname(real)
      end

      def real_or_self(path)
        return nil if path.nil? || path.empty?

        File.realpath(path)
      rescue SystemCallError
        path
      end

      def safe_path(path)
        path && Redact.text(path)
      end

      def missing(path, host, cause)
        text = path.to_s
        text = nil if text.empty? || text.include?("\0")
        text = File.expand_path(text) if text&.start_with?("/")
        build(host, text, "missing", nil, { "cause" => cause })
      end

      def build(host, real_path, resolved, repository_id, attributes)
        path = safe_path(real_path)
        identity = { "kind" => "local", "host" => host, "real_path" => path }
        body = {
          "place_id" => Ids.place_id(identity),
          "kind" => "local",
          "host" => host,
          "real_path" => path,
          "resolved" => resolved,
          "repository_id" => repository_id,
          "attributes" => attributes
        }
        Record::Formats.check_enums(body, PLACE_ENUMS)
        body
      end
    end
  end
end
