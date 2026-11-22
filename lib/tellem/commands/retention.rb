# frozen_string_literal: true

require_relative "../reports/options"
require_relative "../reports/scopes"
require_relative "../retention/run"

module Tellem
  module Commands
    module Retention
      USAGE = "tellem retention [--scope PATH | --all] [--json]"

      module_function

      def run(context)
        options, = Reports::Options.parse(context.args, usage: USAGE, values: %w[--scope], flags: %w[--all])
        scope = options[:scope] && File.expand_path(options[:scope])
        scopes = Reports::Scopes.resolve(scope: scope, all: options[:all] == true)
        report = Tellem::Retention.report(scopes)
        { data: { "scopes" => Reports::Scopes.summary(scopes), "retention" => report }, text: Tellem::Retention.text(report) }
      end
    end
  end
end
