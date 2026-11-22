# frozen_string_literal: true

module Tellem
  module Entries
    module Withhold
      NOTE = "withheld"
      TOOL_RESIDUE = %w[answers].freeze

      module_function

      def apply(batch, policy)
        return batch if policy.nil? || policy.empty?

        ids = {}
        batch.entries.each do |entry|
          next unless entry["kind"] == "action" && withheld_call?(entry, policy)

          entry["content"] = nil
          entry["paths"] = nil
          entry["withheld"] = true
          entry["note"] = NOTE
          ids[entry["call_id"]] = true if entry["call_id"]
        end
        batch.entries.each do |entry|
          next unless entry["kind"] == "output" && ids[entry["call_id"]]

          entry["content"] = nil
          entry["withheld"] = true
          entry["note"] = NOTE
        end
        strip_exchanges(batch, ids, policy)
        strip_calls(batch, ids, policy)
        batch.persona_results.reject! { |result| ids[result["tool_use_id"]] }
        batch
      end

      def withheld_call?(entry, policy)
        return true if policy.tools.include?(entry["tool"])

        Array(entry["paths"]).any? { |path| policy.path_withheld?(path, entry["cwd"]) }
      end

      def strip_exchanges(batch, ids, policy)
        batch.exchanges.each do |exchange|
          tool = exchange["tool"]
          next unless exchange["kind"] == "tool" && tool.is_a?(Hash)
          next unless ids[tool["id"]] || policy.tools.include?(tool["name"])

          tool["input"] = {}
          tool["result"] = nil
          tool["withheld"] = true
          TOOL_RESIDUE.each { |key| tool.delete(key) }
        end
      end

      def strip_calls(batch, ids, policy)
        batch.tool_calls.each do |call|
          next unless ids[call["id"]] || policy.tools.include?(call["name"])

          call["input"] = {}
        end
      end
    end
  end
end
