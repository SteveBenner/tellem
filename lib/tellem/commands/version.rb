# frozen_string_literal: true

module Tellem
  module Commands
    module Version
      module_function

      def run(context)
        raise UsageError.new("version takes no arguments") unless context.args.empty?

        data = {
          "tellem" => Tellem::VERSION,
          "ruby" => RUBY_VERSION,
          "rplugin" => defined?(Rplugin::VERSION) ? Rplugin::VERSION : nil,
          "schemas" => Record::Schemas::ALL
        }
        { data: data, text: "tellem #{Tellem::VERSION}" }
      end
    end
  end
end
