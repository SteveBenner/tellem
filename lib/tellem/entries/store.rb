# frozen_string_literal: true

require "json"
require_relative "../bounds"
require_relative "../ids"
require_relative "../redact"
require_relative "../ingest/support"
require_relative "../record/fs"
require_relative "../record/reader"
require_relative "../record/scope"
require_relative "../record/writer"

module Tellem
  module Entries
    SCHEMA = "tellem.entry/v1"
    DIR = "entries"
    KINDS = %w[prompt reply reasoning action output].freeze
    LINE_ROOM = 65_536
    JSON_EXPANSION = 6
    PART_CHARS = (Bounds::RECORD_BYTES - LINE_ROOM) / JSON_EXPANSION

    module Store
      module_function

      def dir(root, session_key)
        File.join(Record::Scope.session_dir(root, session_key), DIR)
      end

      def path(root, session_key, agent_key)
        raise InvalidRecord.new("invalid agent key") unless Ids.valid_agent_key?(agent_key)

        File.join(dir(root, session_key), "#{agent_key}.jsonl")
      end

      def append(root, session_key, agent_key, batch)
        target = path(root, session_key, agent_key)
        known = existing(target)
        seq = known[:max_seq]
        records = []
        batch.entries.each do |entry|
          next if complete?(known, session_key, agent_key, batch, entry)

          build(session_key, agent_key, batch, entry).each do |record|
            next if known[:ids][record["id"]]

            seq += 1
            records << record.merge("seq" => seq)
          end
        end
        return { "appended" => 0, "skipped" => 0 } if records.empty?

        Record::Writer.append_unique(target, ordered(records))
      end

      def existing(target)
        ids = {}
        parts = {}
        max_seq = 0
        Record::Reader.each(target) do |record|
          next unless record["schema"] == SCHEMA && record["id"].is_a?(String)

          ids[record["id"]] = true
          parts[record["id"]] = record["part"][1] if record["part"].is_a?(Array) && record["part"][0] == 1
          max_seq = record["seq"] if record["seq"].is_a?(Integer) && record["seq"] > max_seq
        end
        { ids: ids, parts: parts, max_seq: max_seq }
      end

      def complete?(known, session_key, agent_key, batch, entry)
        first = identity(session_key, agent_key, batch, entry, 1)
        return false unless known[:ids][first]

        total = known[:parts][first]
        return true if total.nil?

        (2..total).all? { |part| known[:ids][identity(session_key, agent_key, batch, entry, part)] }
      end

      def identity(session_key, agent_key, batch, entry, part)
        Ids.sha256(Ids.canonical_json([SCHEMA, session_key, agent_key, source(batch, entry), entry["kind"], part]))[0, 32]
      end

      def source(batch, entry)
        "#{batch.entry_origin}:#{entry['ref']}"
      end

      def build(session_key, agent_key, batch, entry)
        text = text_of(entry)
        base = {
          "schema" => SCHEMA, "session_key" => session_key, "agent_key" => agent_key, "seq" => 0, "kind" => entry["kind"],
          "at" => entry["at"], "tool" => entry["tool"], "call_id" => entry["call_id"], "part" => [999_999, 999_999],
          "withheld" => entry["withheld"] == true, "note" => entry["note"], "source" => source(batch, entry)
        }
        pieces = split(text, base)
        pieces.each_with_index.map do |piece, index|
          part = pieces.size > 1 ? [index + 1, pieces.size] : nil
          base.merge("id" => identity(session_key, agent_key, batch, entry, index + 1), "text" => piece, "part" => part)
        end
      end

      def text_of(entry)
        content = entry["content"]
        return nil if content.nil?
        return Redact.text(content) if content.is_a?(String)

        JSON.generate(Ingest::Support.deep(content))
      end

      def split(text, base)
        return [text] if text.nil? || fits?(text, base)

        (0...text.length).step(PART_CHARS).map { |from| text[from, PART_CHARS] }
      end

      def fits?(text, base)
        return true if text.bytesize * JSON_EXPANSION + LINE_ROOM <= Bounds::RECORD_BYTES
        return false if text.bytesize + LINE_ROOM > Bounds::RECORD_BYTES

        JSON.generate(base.merge("id" => "0" * 32, "text" => text)).bytesize + 1 <= Bounds::RECORD_BYTES
      end

      def ordered(records)
        records.sort_by { |record| record["seq"] }.map { |record| layout(record) }
      end

      def layout(record)
        record.slice("schema", "id", "session_key", "agent_key", "seq", "kind", "at", "tool", "call_id", "text", "part", "withheld",
                     "note", "source")
      end
    end
  end
end
