# frozen_string_literal: true

require "digest"
require_relative "../redact"

module Tellem
  module Discovery
    module Records
      LINE_LIMIT = 240

      module_function

      def item(id:, kind:, harness: nil, state: "present", known_by: nil, facts: {}, stats: {}, reason: nil)
        {
          "id" => id, "kind" => kind, "harness" => harness, "state" => state, "known_by" => known_by,
          "facts" => facts.compact, "stats" => stats.compact, "reason" => reason
        }.compact
      end

      def unknown(kind, label, error)
        item(id: "#{kind}:#{label}", kind: kind, state: "unknown", known_by: "unknown", reason: reason(error))
      end

      def reason(error)
        case error
        when Exceeded then error.message
        when SystemCallError then "#{error.class.name.split('::').last.downcase.tr('_', ' ')} while reading"
        else error.message
        end
      end

      def clean(text)
        Tellem::Redact.text(text.to_s.strip)[0, LINE_LIMIT]
      end

      def short(text)
        Digest::SHA256.hexdigest(text.to_s)[0, 10]
      end
    end
  end
end
