# frozen_string_literal: true

require "shellwords"
require_relative "../places/git"
require_relative "../record/scope"
require_relative "../record/visibility"
require_relative "entry"

module Tellem
  module Doctor
    module Visibility
      CHECK = "visibility"
      STORES = [Record::Schemas::SCOPE_DIR, Record::Visibility::HISTORY].freeze
      PROBE = "1970-01-01_00-00-00+0000-tellem-probe.md"
      TIMEOUT_MS = 5000

      module_function

      def check(scope_root)
        root = scope_root.to_s
        ignored = user_level
        return ignored + [Entry.ok(CHECK, "user scope; tellem keeps it ignored", { "root" => root })] unless Record::Scope.kind(root) == "repository"

        status = Record::Visibility.status(root)
        found = drift(root, status)
        if status["visibility"] == Record::Visibility::PUBLIC
          found.concat(tracked(root, status))
          found.concat(foreign(root, status))
        end
        found.empty? ? ignored + [Entry.ok(CHECK, "#{status['visibility']} repository; ignore files match", status)] : ignored + found
      end

      def user_level
        value = Config.ignored_value(Record::Visibility::KEY)
        return [] unless value

        [Entry.finding(CHECK, "visibility #{value['value']} is set at the #{value['layer']} level and is ignored; " \
                              "visibility is declared per repository scope", "rplugin settings unset tellem #{Record::Visibility::KEY}", value)]
      end

      def drift(root, status)
        status["drift"].map do |path|
          Entry.finding(CHECK, "#{path} is out of step with visibility #{status['visibility']}",
                        "tellem derive --scope #{Shellwords.escape(root)}", status.merge("path" => path))
        end
      end

      def tracked(root, status)
        result = git(root, ["ls-files", "-z", "--", *STORES])
        unless result.ok?
          return [Entry.finding(CHECK, "could not list tracked files in #{root} (#{result.cause})",
                                "git -C #{Shellwords.escape(root)} ls-files -- #{STORES.join(' ')}", status)]
        end

        paths = result.stdout.to_s.split("\0").reject(&:empty?)
        STORES.map do |store|
          hits = paths.select { |path| path == store || path.start_with?("#{store}/") }
          next if hits.empty?

          Entry.finding(CHECK, "#{hits.size} file#{hits.size == 1 ? '' : 's'} under #{store} tracked in public repository #{root}",
                        "git -C #{Shellwords.escape(root)} rm -r --cached #{store}",
                        status.merge("store" => store, "tracked" => hits.first(16)))
        end.compact
      end

      def foreign(root, status)
        return [] unless status["history"] == "foreign"

        probe = File.join(Record::Visibility::HISTORY, PROBE)
        result = git(root, ["check-ignore", "-q", "--no-index", "--", probe])
        return [] if result.ok?

        path = Record::Visibility.history_ignore(root)
        detail = status.merge("path" => path)
        return [Entry.finding(CHECK, "could not check whether #{path} ignores tellem's copies (#{result.cause})",
                              "git -C #{Shellwords.escape(root)} check-ignore -v --no-index #{probe}", detail)] unless result.exit_code == 1

        [Entry.finding(CHECK, "#{path} is not tellem's and does not ignore tellem's copies in public repository #{root}",
                       "printf '*\\n' >> #{Shellwords.escape(path)}", detail)]
      end

      def git(root, args)
        Places::Git.run(args, chdir: root, timeout_ms: TIMEOUT_MS)
      end
    end
  end
end
