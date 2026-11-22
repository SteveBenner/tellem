# frozen_string_literal: true

require_relative "../entries/policy"
require_relative "../entries/store"
require_relative "../ids"
require_relative "../record/fs"
require_relative "../record/reader"
require_relative "../record/scope"

module Tellem
  module Retention
    module ToolCounts
      CONDITION = "tool_count_mismatch"
      TOOL_OPEN = /\A<tool-use data-tool-type="[^"]*" data-tool-name="([^"]*)"><details>\s*\z/
      TOOL_CLOSE = "</details></tool-use>"
      FENCE = /\A(`{3,})(\S*)\s*\z/
      RESULT_FENCE = "text"
      ASK = "AskUserQuestion"
      WRITE = "Write"
      OMITTED = "content_omitted:"
      USE_BLOCKS = %w[tool_use server_tool_use].freeze

      module_function

      def condition(context, result)
        session = result.session
        withheld = !Entries::Policy.resolve(context).empty?
        differences = session.natives.keys.sort.each_with_object({}) do |agent, out|
          native = native_counts(session, agent)
          kept = record_counts(context, session, agent)
          diff = compare(native, kept, withheld)
          out[agent] = { "native" => native, "record" => kept } if diff
        end
        return nil if differences.empty?

        result.detail = (result.detail || {}).merge("tool_counts" => differences)
        CONDITION
      end

      def compare(native, kept, withheld)
        return true if native["uses"] != kept["uses"]

        !withheld && native["results"] != kept["results"]
      end

      def native_counts(session, agent)
        path = session.natives[agent]["path"]
        return codex_counts(session, agent, path) if session.harness == "codex"

        uses = 0
        names = {}
        results = {}
        Record::Reader.each(path) do |entry|
          content = entry.dig("message", "content")
          next unless content.is_a?(Array)

          content.grep(Hash).each do |block|
            if entry["type"] == "assistant" && USE_BLOCKS.include?(block["type"])
              uses += 1
              names[block["id"]] = block["name"]
            elsif entry["type"] == "user" && block["type"] == "tool_result" && !block["content"].nil?
              results[block["tool_use_id"]] = true
            end
          end
        end
        { "uses" => uses, "results" => results.keys.count { |id| names.key?(id) && names[id] != ASK } }
      end

      def codex_counts(session, agent, path)
        batch = session.context.seam(:ingest_codex).read(path, session_id: session.session_id, agent_key: agent)
        tools = batch.exchanges.select { |exchange| exchange["kind"] == "tool" }.map { |exchange| exchange["tool"] }
        { "uses" => tools.size, "results" => tools.count { |tool| !tool["result"].nil? && tool["name"] != ASK } }
      end

      def record_counts(context, session, agent)
        name = context.cursor.rendered(session.key, agent)
        path = name.is_a?(String) ? File.join(Record::Scope.transcripts_dir(session.root, session.key), name) : nil
        markdown(path)
      end

      def markdown(path)
        counts = { "uses" => 0, "results" => 0 }
        return counts unless path && Record::FS.lstat(path)&.file?

        fence = nil
        block = nil
        Record::FS.open_read(path) do |file|
          file.each_line do |raw|
            line = raw.dup.force_encoding(Encoding::BINARY).chomp
            if fence
              fence = nil if line.strip == fence
              next
            end
            if (match = FENCE.match(line))
              fence = match[1]
              if block
                block[:fences] += 1
                block[:last] = match[2]
              end
            elsif (match = TOOL_OPEN.match(line))
              counts["uses"] += 1
              block = { name: match[1], fences: 0, last: nil, omitted: false }
            elsif block && line.include?(OMITTED)
              block[:omitted] = true
            elsif block && line.start_with?(TOOL_CLOSE)
              counts["results"] += 1 if answered?(block)
              block = nil
            end
          end
        end
        counts
      end

      def answered?(block)
        return false if block[:name] == ASK || block[:last] != RESULT_FENCE
        return block[:fences] > 1 || block[:omitted] if block[:name] == WRITE

        true
      end
    end
  end
end
