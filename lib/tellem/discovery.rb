# frozen_string_literal: true

require "digest"
require "json"
require_relative "version"
require_relative "ports/harness_paths"
require_relative "entries/policy"
require_relative "discovery/bounds"
require_relative "discovery/binary"
require_relative "discovery/capabilities"
require_relative "discovery/records"
require_relative "discovery/settings"
require_relative "discovery/stores"
require_relative "discovery/switches"
require_relative "discovery/hooks"
require_relative "discovery/incumbent"
require_relative "discovery/readers"

module Tellem
  module Discovery
    SCHEMA = "tellem.discovery/v1"
    HARNESSES = %w[claude codex].freeze
    SOURCES = [
      ["native_store", Stores, :native],
      ["prompt_history", Stores, :history],
      ["capability", Switches, :capabilities],
      ["hook", Hooks, :hooks],
      ["codex_trust", Hooks, :codex_trust],
      ["tellem", Hooks, :tellem],
      ["wrapper", Incumbent, :wrappers],
      ["process", Incumbent, :processes],
      ["schedule", Incumbent, :schedules],
      ["repo_output", Incumbent, :repo_outputs],
      ["specstory_state", Incumbent, :state],
      ["otel", Switches, :otel]
    ].freeze
    ACTIVE_KINDS = %w[wrapper process schedule].freeze

    Context = Struct.new(:paths, :harnesses, :scans, :claude_files, :codex_config, keyword_init: true) do
      def harness(id)
        harnesses.fetch(id)
      end

      def scan(id)
        scans.fetch(id)
      end
    end

    module_function

    def run(home_paths)
      ctx = context(home_paths.merge(declared_readers: declared(home_paths)))
      methods = SOURCES.flat_map { |kind, mod, name| guarded(kind, name) { |deadline| mod.public_send(name, ctx, deadline) } }
      controls = guarded("control", :controls) { |deadline| Switches.controls(ctx, deadline) }
      readers = guarded("reader", :collect, seconds: Readers::PLUGIN_SECONDS * 2) { |deadline| Readers.collect(ctx, deadline) }
      readers << specstory_reader(methods) if specstory_active?(methods)
      report = {
        "schema" => SCHEMA,
        "harnesses" => ctx.harnesses.values,
        "methods" => methods.sort_by { |entry| [entry["id"], JSON.generate(entry["facts"] || {})] },
        "readers" => readers.sort_by { |entry| entry["id"] },
        "controls" => controls.sort_by { |entry| entry["id"] }
      }
      report.merge("digest" => digest(report))
    end

    def declared(home_paths)
      return home_paths[:declared_readers] if home_paths.key?(:declared_readers)
      return [] unless defined?(Rplugin::Ports)

      policy = Entries::Policy.resolve
      policy.failed? ? ["policy_failed"] : policy.readers
    end

    def guarded(kind, name, seconds: Bounds::SOURCE_SECONDS)
      yield Bounds.deadline(seconds)
    rescue Exceeded, SystemCallError, IOError, ArgumentError => e
      [Records.unknown(kind, name, e)]
    end

    def context(paths)
      port = paths[:harness_port] || default_port
      harnesses = HARNESSES.to_h { |id| [id, harness_record(id, paths, port)] }
      scans = harnesses.to_h do |id, record|
        scan = Binary.scan(record.dig("binary", "real_path"), Capabilities.needles(id))
        scan = scan.merge(reason: "#{id} is not installed") if record["binary"]["path"].nil?
        record["binary"]["scan"] = scan[:reason] ? "unknown" : "complete"
        record["binary"]["reason"] = scan[:reason]
        record["binary"].compact!
        [id, scan]
      end
      Context.new(paths: paths, harnesses: harnesses, scans: scans, claude_files: Settings.claude_files(paths), codex_config: Settings.codex_config(paths))
    end

    def default_port
      return nil unless defined?(Ports::Harness)

      Ports::Harness.new(plugin_id: Ports::HarnessPaths::PLUGIN_ID, root: Tellem.root)
    end

    def harness_record(id, paths, port)
      binary = port&.harness_binary(id)
      {
        "id" => id, "installed" => !binary.nil?, "version" => port&.harness_version(id),
        "home" => id == "claude" ? paths[:claude_home] : paths[:codex_home],
        "binary" => { "path" => binary, "real_path" => binary && Bounds.real(binary) }
      }
    end

    def specstory_active?(methods)
      methods.any? do |entry|
        entry["state"] == "present" && (ACTIVE_KINDS.include?(entry["kind"]) ||
          (entry["kind"] == "hook" && Array(entry.dig("facts", "captures")).include?("specstory_sync")))
      end
    end

    def specstory_reader(methods)
      evidence = methods.select do |entry|
        entry["state"] == "present" && (ACTIVE_KINDS.include?(entry["kind"]) || Array(entry.dig("facts", "captures")).include?("specstory_sync"))
      end
      { "id" => "specstory", "kind" => "incumbent", "evidence" => evidence.map { |entry| { "method" => entry["id"] } }.first(Readers::EVIDENCE_CAP), "confidence" => "confirmed" }
    end

    def digest(report)
      view = {
        "schema" => report["schema"],
        "harnesses" => report["harnesses"],
        "methods" => report["methods"].reject { |entry| entry["kind"] == "process" }.map { |entry| entry.reject { |key, _| key == "stats" } },
        "readers" => report["readers"].map { |entry| entry.merge("evidence" => entry["evidence"].map { |item| item.reject { |key, _| key == "line" } }) },
        "controls" => report["controls"]
      }
      Digest::SHA256.hexdigest(JSON.generate(canonical(view)))
    end

    def canonical(node)
      case node
      when Hash then node.sort_by { |key, _| key.to_s }.to_h { |key, value| [key, canonical(value)] }
      when Array then node.map { |value| canonical(value) }
      else node
      end
    end
  end
end
