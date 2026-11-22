# frozen_string_literal: true

require_relative "bounds"
require_relative "records"

module Tellem
  module Discovery
    module Stores
      module_function

      def native(ctx, deadline)
        paths = ctx.paths
        [
          directory("native_store:claude:projects", "claude", File.join(paths[:claude_home], "projects"), deadline),
          directory("native_store:codex:sessions", "codex", File.join(paths[:codex_home], "sessions"), deadline),
          directory("native_store:codex:archived_sessions", "codex", File.join(paths[:codex_home], "archived_sessions"), deadline),
          state_database(paths)
        ]
      end

      def history(ctx, _deadline)
        paths = ctx.paths
        [
          file_entry("prompt_history:claude", "claude", File.join(paths[:claude_home], "history.jsonl")),
          file_entry("prompt_history:codex", "codex", File.join(paths[:codex_home], "history.jsonl"))
        ]
      end

      def directory(id, harness, path, deadline)
        real = Bounds.real(path)
        unless real && Bounds.stat(real)&.directory?
          return Records.item(id: id, kind: "native_store", harness: harness, state: "absent", known_by: "table", facts: { "path" => path })
        end

        counts = Hash.new(0)
        bytes = 0
        Bounds.walk(real, deadline: deadline) do |file, info|
          counts[category(file)] += 1
          bytes += info.size
        end
        Records.item(id: id, kind: "native_store", harness: harness, known_by: "table",
                     facts: { "path" => path, "real_path" => real },
                     stats: { "files" => counts.sort.to_h, "bytes" => bytes })
      end

      def category(path)
        name = File.basename(path)
        return "jsonl_zst" if name.end_with?(".jsonl.zst")
        return "jsonl" if name.end_with?(".jsonl")

        "other"
      end

      def state_database(paths)
        names = Bounds.children(paths[:codex_home]).grep(/\Astate_\d+\.sqlite(?:-wal|-shm)?\z/)
        if names.empty?
          return Records.item(id: "native_store:codex:state", kind: "native_store", harness: "codex", state: "absent", known_by: "table",
                              facts: { "path" => paths[:codex_home] })
        end

        bytes = names.sum { |name| Bounds.lstat(File.join(paths[:codex_home], name))&.size.to_i }
        Records.item(id: "native_store:codex:state", kind: "native_store", harness: "codex", known_by: "table",
                     facts: { "path" => paths[:codex_home], "files" => names }, stats: { "bytes" => bytes })
      end

      def file_entry(id, harness, path)
        info = Bounds.stat(path)
        return Records.item(id: id, kind: "prompt_history", harness: harness, state: "absent", known_by: "table", facts: { "path" => path }) unless info&.file?

        Records.item(id: id, kind: "prompt_history", harness: harness, known_by: "table", facts: { "path" => path }, stats: { "bytes" => info.size })
      end
    end
  end
end
