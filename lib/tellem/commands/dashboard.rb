# frozen_string_literal: true

require "rbconfig"
require_relative "../dashboard/collector"
require_relative "../dashboard/dataset"
require_relative "../dashboard/share"
require_relative "../dashboard/writer"
require_relative "../reports/options"
require_relative "../reports/text"

module Tellem
  module Commands
    module Dashboard
      USAGE = "tellem dashboard [--share] [--no-open] [--json]"
      OPENERS = { /linux/ => "xdg-open", /darwin/ => "open" }.freeze

      module_function

      def run(context)
        options, _rest = Reports::Options.parse(context.args, usage: USAGE, flags: %w[--share --no-open])
        require_relative "../dashboard/page" unless context.json
        dataset = Tellem::Dashboard::Dataset.build(Tellem::Dashboard::Collector.run)
        dataset = Tellem::Dashboard::Share.apply(dataset) if options[:share]
        return { data: dataset } if context.json

        written = Tellem::Dashboard::Writer.write(dataset)
        note = options[:no_open] ? nil : open_note(context.stdout, written.path)
        summary(written, dataset, note)
      end

      def summary(written, dataset, note)
        line = "#{written.path}  #{written.bytes} bytes  as of #{dataset['as_of']}  #{dataset['sessions'].size} sessions"
        data = { "path" => written.path, "bytes" => written.bytes, "as_of" => dataset["as_of"], "sessions" => dataset["sessions"].size }
        { data: data, text: Reports::Text.with_notes(line, [note]) }
      end

      def open_note(stdout, path)
        return nil unless stdout.respond_to?(:tty?) && stdout.tty?

        program = OPENERS.find { |pattern, _program| pattern.match?(RbConfig::CONFIG["host_os"]) }&.last
        return "note: no file opener is known for this platform" unless program

        launch(program, path)
      end

      def launch(program, path)
        Process.detach(Process.spawn(program, path, in: File::NULL, out: File::NULL, err: File::NULL, pgroup: true))
        nil
      rescue SystemCallError => e
        "note: #{program} could not be started (#{e.class.name})"
      end
    end
  end
end
