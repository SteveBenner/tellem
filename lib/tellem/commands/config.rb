# frozen_string_literal: true

require_relative "../config/resolver"
require_relative "../errors"
require_relative "../record/visibility"
require_relative "../reports/options"
require_relative "../reports/scopes"
require_relative "../reports/text"

module Tellem
  module Commands
    module Config
      USAGE = "tellem config get KEY | set KEY VALUE | list [--scope PATH] [--json]"
      ARITY = { "get" => 1..1, "set" => 2..2, "list" => 0..0 }.freeze

      module_function

      def run(context)
        args = context.args.dup
        sub = args.shift
        raise UsageError.new(USAGE) unless ARITY.key?(sub)

        options, rest = Reports::Options.parse(args, usage: USAGE, values: %w[--scope], positional: ARITY.fetch(sub))
        explicit = options[:scope] && Reports::Scopes.root_for(File.expand_path(options[:scope]))
        effective = explicit || Record::Scope.locate(Dir.pwd)
        case sub
        when "get" then show(Tellem::Config.explain(rest[0], scope: effective), effective)
        when "set"
          Tellem::Config.refuse_cutover_only!(rest[0], rest[1])
          excluded = excluded_repository(rest[0].to_s, options[:scope] || Dir.pwd)
          return excluded if excluded

          target =Tellem::Config.scope_only?(rest[0].to_s) ? explicit || effective : explicit
          reconciled(show(Tellem::Config.set(rest[0], rest[1], scope: target), target), effective)
        when "list" then listing(Tellem::Config.list(scope: effective), effective)
        end
      end

      def excluded_repository(key, path)
        return nil unless Tellem::Config.scope_only?(key)

        repository = Record::Scope.repository_above(File.expand_path(path))
        return nil unless repository && Record::Exclude.covers?(repository)

        root = Record::Exclude.covering(repository)
        under = root ? "the excluded root #{root}" : "scope.exclude_roots, which cannot be read, so every repository counts as excluded"
        data = { "key" => key, "value" => nil, "layer" => "excluded", "scope" => repository, "excluded_root" => root }
        { data: data, text: "#{repository} is under #{under}; tellem writes no scope there, so #{key} is not set and the user scope keeps *" }
      end

      def reconciled(result, scope)
        return result unless result[:data]["key"] == Record::Visibility::KEY

        outcome = Record::Visibility.reconcile(scope)
        result[:data]["reconciled"] = outcome
        count = outcome["changed"].size
        note = "reconciled #{outcome['root']}: #{outcome['visibility']}, #{count} ignore file#{count == 1 ? '' : 's'} changed"
        result.merge(text: "#{result[:text]}\n#{note}")
      end

      def row(entry, scope)
        { "key" => entry[:key], "value" => entry[:value], "layer" => entry[:layer], "scope" => scope }
      end

      def show(entry, scope)
        data = row(entry, scope)
        { data: data, text: "#{data['key']} = #{Reports::Text.cell(data['value'])} (#{data['layer']})" }
      end

      def listing(entries, scope)
        rows = entries.map { |entry| row(entry, scope) }
        table = rows.map { |item| [item["key"], Reports::Text.cell(item["value"]), item["layer"].to_s] }
        { data: { "scope" => scope, "settings" => rows }, text: Reports::Text.table(%w[key value layer], table) }
      end
    end
  end
end
