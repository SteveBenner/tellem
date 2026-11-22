# frozen_string_literal: true

require_relative "../config/resolver"
require_relative "../errors"
require_relative "../ports/harness_paths"
require_relative "../record/fs"
require_relative "../record/scope"
require_relative "../reports/options"
require_relative "../reports/scopes"
require_relative "../reports/text"
require_relative "../cutover/discover"
require_relative "../parity/history"
require_relative "../parity/ledger"

module Tellem
  module Commands
    module Shadow
      USAGE = "tellem shadow status [--scope PATH | --all] [--json]"

      module_function

      def run(context)
        args = context.args.dup
        raise UsageError.new(USAGE) unless args.shift == "status"

        options, = Reports::Options.parse(args, usage: USAGE, values: %w[--scope], flags: %w[--all])
        scope = options[:scope] && File.expand_path(options[:scope])
        scopes = Reports::Scopes.resolve(scope: scope, all: options[:all] == true)
        data = status(scopes)
        { data: data, text: text(data) }
      end

      def status(scopes)
        ai_home = Ports::HarnessPaths.ai_home
        found = ai_home ? Cutover::Discover.run(ai_home) : { "hooks" => [], "registrations" => [] }
        {
          "cutover_state" => Config.get("cutover.state"),
          "capture" => { "setting" => Config.get("features.capture") == true,
                         "flag" => Record::FS.lexists?(Ports::HarnessPaths.capture_flag), "kill_switch" => Config.disabled?(:capture) },
          "derive" => Config.get("features.derive") == true,
          "ai_home" => ai_home,
          "incumbents" => incumbents(found),
          "scopes" => scopes.map { |item| scope_status(item) }
        }
      end

      def incumbents(found)
        found["hooks"].map do |hook|
          events = found["registrations"].select { |entry| entry["hook"] == hook["name"] }.map { |entry| entry["event"] }.uniq.sort
          hook.merge("registered" => !events.empty?, "events" => events)
        end
      end

      def scope_status(item)
        root = item["root"]
        counts = Hash.new(0)
        Record::Scope.session_keys(root).each { |key| counts[key.split("-", 2).first] += 1 } unless item["gone"]
        history = Parity::History.new(root)
        {
          "scope_id" => item["scope_id"], "root" => root, "kind" => item["kind"], "gone" => item["gone"],
          "cutover_state" => item["gone"] ? nil : Config.get("cutover.state", scope: root),
          "sessions" => { "claude" => counts["claude"], "codex" => counts["codex"] },
          "specstory_history" => history.names.size,
          "ledger" => Record::FS.lstat(Parity::Ledger.path(root))&.file? ? true : false
        }
      end

      def text(data)
        lines = ["cutover.state #{data['cutover_state']}; capture #{data['capture']['setting'] ? 'on' : 'off'} " \
                 "(flag #{data['capture']['flag'] ? 'present' : 'absent'}#{data['capture']['kill_switch'] ? ', TELLEM_DISABLED=1' : ''}); " \
                 "derive #{data['derive'] ? 'on' : 'off'}"]
        lines << "~/.ai #{data['ai_home'] || 'not found'}"
        data["incumbents"].each do |hook|
          lines << "  incumbent #{hook['path']} (#{hook['captures'].join(', ')}): #{hook['registered'] ? "registered on #{hook['events'].join(', ')}" : 'not registered'}"
        end
        rows = data["scopes"].map do |scope|
          [scope["root"], scope["cutover_state"].to_s, scope["sessions"]["claude"].to_s, scope["sessions"]["codex"].to_s,
           scope["specstory_history"].to_s, scope["ledger"] ? "yes" : "no"]
        end
        lines << Reports::Text.table(%w[SCOPE CUTOVER CLAUDE CODEX SPECSTORY LEDGER], rows)
        lines.join("\n")
      end
    end
  end
end
