# frozen_string_literal: true

require_relative "../redact"
require_relative "../record/fs"
require_relative "../record/kinds"
require_relative "../record/formats"
require_relative "../record/scope"
require_relative "git"
require_relative "local"

module Tellem
  module Places
    module Workspace
      ENUMS = Record::Kinds.fetch("workspace")[:enums]
      AHEAD_BEHIND = /\A\+(?<ahead>\d+) -(?<behind>\d+)\z/
      STATUS_ARGS = %w[status --porcelain=v2 --branch].freeze

      module_function

      def available?
        true
      end

      def foundation_default?
        false
      end

      def sample(root, timeout_ms: Git::DEFAULT_TIMEOUT_MS, host: Record::FS.host)
        started = Git.now_ms
        stop_at = started + Git.bound(timeout_ms)
        sampled_at = Record::FS.rfc3339_ms
        place = Local.resolve(root, host: host, repository: false)
        body = base(place["place_id"], sampled_at)
        cause = precheck(place)
        return finish(body.merge("cause" => cause), started) if cause

        body["worktree"] = worktree_kind(place["real_path"])
        found = Git.run(STATUS_ARGS, chdir: place["real_path"], until_ms: stop_at)
        return finish(body.merge("cause" => unknown_cause(found)), started) unless found.ok?

        finish(body.merge(parse(found.lines)).merge("status" => "ok", "cause" => nil), started)
      end

      def base(place_id, sampled_at)
        {
          "place_id" => place_id,
          "sampled_at" => sampled_at,
          "status" => "unknown",
          "cause" => nil,
          "branch" => nil,
          "dirty" => nil,
          "worktree" => nil,
          "ahead" => nil,
          "behind" => nil,
          "duration_ms" => nil
        }
      end

      def precheck(place)
        return "other_host" if place.dig("attributes", "cause") == "other_host"
        return "root_missing" unless place["resolved"] == "full" && File.directory?(place["real_path"].to_s)

        nil
      end

      def unknown_cause(found)
        case found.status
        when :timeout then "timeout"
        when :unavailable then "git_unavailable"
        else found.exit_code == 128 ? "not_a_repository" : "git_failed"
        end
      end

      def parse(lines)
        out = { "branch" => nil, "dirty" => false, "ahead" => nil, "behind" => nil, "detached" => false }
        lines.each do |line|
          if line.start_with?("# branch.head ")
            head = line.delete_prefix("# branch.head ")
            head == "(detached)" ? out["detached"] = true : out["branch"] = Redact.text(head)
          elsif line.start_with?("# branch.ab ")
            match = AHEAD_BEHIND.match(line.delete_prefix("# branch.ab "))
            out["ahead"], out["behind"] = [match[:ahead].to_i, match[:behind].to_i] if match
          elsif !line.start_with?("# ") && !line.empty?
            out["dirty"] = true
          end
        end
        out
      end

      def worktree_kind(root)
        dotgit = File.join(root, ".git")
        stat = Record::FS.lstat(dotgit)
        return nil unless stat
        return "main" if stat.directory?
        return nil unless stat.file?

        gitdir = Record::Scope.linked_gitdir(dotgit, root)
        return nil unless gitdir

        File.file?(File.join(gitdir, "commondir")) ? "linked" : "main"
      end

      def finish(body, started)
        body["duration_ms"] = Git.now_ms - started
        Record::Formats.check_enums(body, ENUMS)
        body
      end
    end
  end
end
