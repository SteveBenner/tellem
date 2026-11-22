# frozen_string_literal: true

require_relative "../config/resolver"
require_relative "../errors"
require_relative "../seams"

module Tellem
  module Reports
    module Refresh
      WAIT_S = 10

      module_function

      def run(scopes, strict: false, wait_s: WAIT_S, skip: false)
        return { "status" => "skipped" } if skip

        roots = scopes.reject { |item| item["gone"] }.map { |item| item["root"] }
        return { "status" => "unavailable" } unless Seams.registered?(:deriver)
        return { "status" => "disabled" } if Config.disabled?(:derive)
        return { "status" => "ok", "scopes" => 0 } if roots.empty?

        deriver = Seams.fetch(:deriver)
        failures = []
        worker = Thread.new do
          roots.each do |root|
            deriver.run(root, wait: true)
          rescue StandardError => e
            failures << { "root" => root, "error_class" => e.class.name }
          end
        end
        worker.report_on_exception = false
        return finished(roots, failures) if worker.join(wait_s)

        if strict
          raise Busy.new("the deriver did not finish within #{wait_s} s for #{roots.join(', ')}",
                         next_command: "tellem sync --scope #{roots.first}")
        end

        { "status" => "timeout", "wait_s" => wait_s }
      end

      def finished(roots, failures)
        return { "status" => "ok", "scopes" => roots.size } if failures.empty?

        { "status" => "failed", "scopes" => roots.size, "failures" => failures }
      end

      def note(state)
        case state["status"]
        when "timeout" then "note: the deriver did not finish within #{state['wait_s']} s; this answer is from what is durable"
        when "failed" then "note: the deriver failed for #{state['failures'].map { |item| item['root'] }.join(', ')}; this answer is from what is durable"
        when "unavailable" then "note: no deriver is installed; this answer is from what is durable"
        when "skipped" then "note: --no-derive; this answer is from what is durable"
        when "disabled" then "note: TELLEM_DERIVE_DISABLED=1; this answer is from what is durable"
        end
      end
    end
  end
end
