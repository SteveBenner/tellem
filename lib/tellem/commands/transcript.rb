# frozen_string_literal: true

module Tellem
  module Commands
    module Transcript
      USAGE = "transcript show AGENT [--scope PATH]; AGENT is SESSION_KEY, SESSION_KEY/AGENT_KEY, or a subagent id"
      SUBAGENT = /--subagent-([A-Za-z0-9_-]+)\.md\z/

      module_function

      def run(context)
        args = context.args.dup
        raise UsageError.new(USAGE) unless args.shift == "show"

        scope = option(args, "--scope")
        agent = args.shift
        raise UsageError.new(USAGE) if agent.nil? || agent.start_with?("-") || !args.empty?

        root = Record::Scope.locate(scope || Dir.pwd)
        refresh(root)
        path, session_key, agent_key = find(root, agent)
        markdown = Record::FS.read(path)
        data = { "path" => path, "session_key" => session_key, "agent_key" => agent_key, "markdown" => markdown }
        { data: data, text: markdown }
      end

      def option(args, name)
        index = args.index(name)
        return nil unless index

        value = args[index + 1]
        raise UsageError.new(USAGE) if value.nil? || value.start_with?("-")

        args.slice!(index, 2)
        File.expand_path(value)
      end

      def refresh(root)
        return unless Seams.registered?(:deriver)

        Seams.fetch(:deriver).run(root, wait: true)
      rescue Tellem::Error
        nil
      end

      def find(root, agent)
        session_key, agent_key = agent.split("/", 2)
        matches = if agent_key
                    in_session(root, session_key, agent_key)
                  elsif Ids.valid_session_key?(agent)
                    in_session(root, agent, Ids::MAIN_AGENT)
                  else
                    by_agent_id(root, agent)
                  end
        return matches.first if matches.size == 1

        unavailable(root, agent) if matches.empty?
        raise OperationalFailure.new("#{agent} matches #{matches.size} transcripts in #{root}",
                                     next_command: "tellem transcript show SESSION_KEY/AGENT_KEY --scope #{root}")
      end

      def in_session(root, session_key, agent_key)
        return [] unless Ids.valid_session_key?(session_key)

        files(root, session_key).select { |(_path, _key, key)| key == agent_key }
      end

      def by_agent_id(root, agent_id)
        key = Ids.agent_key(agent_id)
        return [] unless key && key == agent_id

        Record::Scope.session_keys(root).flat_map { |session_key| files(root, session_key) }.select { |(_path, _key, agent_key)| agent_key == key }
      end

      def files(root, session_key)
        dir = Record::Scope.transcripts_dir(root, session_key)
        return [] if Record::FS.lstat(dir).nil? || Record::FS.lstat(dir).symlink?

        Dir.children(dir).sort.filter_map do |name|
          next unless name.end_with?(".md") && !name.start_with?(".")

          path = File.join(dir, name)
          stat = Record::FS.lstat(path)
          next unless stat&.file?

          [path, session_key, name[SUBAGENT, 1] || Ids::MAIN_AGENT]
        end
      rescue SystemCallError
        []
      end

      def unavailable(root, agent)
        cause = Record::FS.lexists?(Record::Scope.dir(root)) ? "no transcript for #{agent} in #{root}" : "no tellem scope at #{root}"
        raise CapabilityUnavailable.new(cause, next_command: "tellem sync --scope #{root}")
      end
    end
  end
end
