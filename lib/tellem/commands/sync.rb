# frozen_string_literal: true

require_relative "../config/resolver"
require_relative "../entries/reader"
require_relative "../errors"
require_relative "../ids"
require_relative "../reports/scopes"
require_relative "../seams"

module Tellem
  module Commands
    module Sync
      USAGE = "sync [--scope PATH | --all] | sync --session KEY [--scope PATH] [--timeout SECONDS]"
      DEFAULT_TIMEOUT_S = 30
      MAX_TIMEOUT_S = 600

      module_function

      def run(context)
        args = context.args.dup
        session = take(args, "--session")
        timeout = take(args, "--timeout")
        return by_session(session, timeout, args) if session

        raise UsageError.new(USAGE) if timeout

        roots = roots(args)
        deriver = Seams.fetch(:deriver)
        summaries = roots.map { |root| deriver.run(root, wait: true) }
        busy = summaries.select { |summary| summary["status"] == "busy" }
        unless busy.empty?
          raise Busy.new("deriver lock held past #{Deriver::WAIT_S} s on #{busy.map { |summary| summary['scope_root'] }.join(', ')}",
                         next_command: "tellem sync --scope #{busy.first['scope_root']}",
                         detail: { "scopes" => summaries })
        end

        { data: { "scopes" => summaries }, text: summaries.map { |summary| line(summary) }.join("\n") }
      end

      def take(args, name)
        index = args.index(name)
        return nil unless index

        value = args[index + 1]
        raise UsageError.new(USAGE) if value.nil? || value.start_with?("-")

        args.slice!(index, 2)
        value
      end

      def by_session(key, timeout, args)
        raise UsageError.new(USAGE) unless Ids.valid_session_key?(key)

        seconds = timeout_seconds(timeout)
        scope = take(args, "--scope")
        raise UsageError.new(USAGE) unless args.empty?

        root = Reports::Scopes.root_for(File.expand_path(scope || Dir.pwd))
        home = Entries::Reader.home_root(root, key) || root
        summary = bounded_run(home, key, seconds)
        found = Entries::Reader.home_root(root, key)
        raise CapabilityUnavailable.new("no session #{key} in #{root}", next_command: "tellem sessions --scope #{root}") unless found

        counts = Entries::Reader.load(found, key).transform_values(&:size)
        enabled = Config.get("transcripts.entries", scope: found) == true
        data = { "session_key" => key, "scope_root" => found, "status" => summary["status"], "entries_enabled" => enabled, "entries" => counts }
        { data: data, text: "#{key}: #{summary['status']}, entries #{counts.empty? ? 'none' : counts.map { |agent, n| "#{agent}=#{n}" }.join(' ')}" }
      end

      def timeout_seconds(value)
        return DEFAULT_TIMEOUT_S if value.nil?

        number = Integer(value, 10)
        raise ArgumentError unless number.positive? && number <= MAX_TIMEOUT_S

        number
      rescue ArgumentError
        raise UsageError.new("--timeout must be an integer from 1 to #{MAX_TIMEOUT_S}: #{USAGE}")
      end

      def bounded_run(home, key, seconds)
        worker = Thread.new do
          Thread.current.report_on_exception = false
          Seams.fetch(:deriver).run(home, wait: true, wait_s: seconds)
        end
        summary = worker.join(seconds) ? worker.value : nil
        if summary.nil? || summary["status"] == "busy"
          worker.kill
          raise Busy.new("sync of #{key} did not finish within #{seconds} s; entries may be behind",
                         next_command: "tellem sync --session #{key} --scope #{home} --timeout #{seconds * 2}",
                         detail: { "timed_out" => true, "timeout_s" => seconds, "session_key" => key, "scope_root" => home })
        end
        summary
      end

      def roots(args)
        all = !args.delete("--all").nil?
        index = args.index("--scope")
        scope = nil
        if index
          scope = args[index + 1]
          raise UsageError.new(USAGE) if scope.nil? || scope.start_with?("-")

          args.slice!(index, 2)
        end
        raise UsageError.new(USAGE) unless args.empty? && !(all && scope)
        return [File.expand_path(scope || Dir.pwd)] unless all

        Record::Registry.resolve.reject { |entry| entry["gone"] }.map { |entry| entry["root"] }.uniq.sort
      end

      def line(summary)
        "#{summary['scope_root']}: #{summary['status']}, #{summary['passes']} passes, #{summary['sessions']} sessions, " \
          "#{summary['observations_added']} observations, #{summary['gaps_added']} gaps, #{summary['duration_ms']} ms"
      end
    end
  end
end
