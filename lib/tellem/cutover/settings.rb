# frozen_string_literal: true

require_relative "../config/resolver"
require_relative "../errors"

module Tellem
  module Cutover
    module Settings
      APPLIED = [["cutover.state", "cutover"], ["retention.native", true]].freeze
      OTEL = [["otel.receiver", true]].freeze
      DEFAULTS = { "retention.native_days" => 14, "otel.port" => 43_180 }.freeze
      USER = "user"
      WINDOW = "retention.native_days"

      module_function

      def planned(otel: false, flip: true, retention: true, levels: {}, purge: false, receiver: false)
        items = []
        items << ["cutover.state", "cutover"] if flip
        items << ["retention.native", true] if retention
        items.concat(OTEL) if otel || receiver
        levels.each { |name, level| items << ["authority.#{name}", level] }
        items << ["retention.purge", true] if purge
        items.map { |key, value| { "key" => key, "value" => value } }
      end

      def window_days
        value("retention.native_days")
      end

      def otel_port
        value("otel.port")
      end

      def value(key, scope: nil)
        found = declared?(key) ? Config.get(key, scope: scope) : nil
        return found if key == WINDOW && found == 0
        found.is_a?(Integer) && found.positive? ? found : DEFAULTS.fetch(key)
      end

      def declared?(key)
        Config.entry(key)
        true
      rescue UsageError
        false
      end

      def require_declared(settings)
        missing = settings.map { |item| item["key"] }.reject { |key| declared?(key) }
        return if missing.empty?

        raise CapabilityUnavailable.new(
          "tellem.rplugin.yml declares no setting #{missing.join(', ')}, so cutover cannot set it",
          next_command: "declare #{missing.join(', ')} in tellem.rplugin.yml (specs/tellem.impl.yml settings), then tellem cutover plan"
        )
      end

      def priors(settings)
        settings.map do |item|
          row = Config.settings.explain(item["key"]).find { |entry| entry[:layer] == USER } || {}
          { "key" => item["key"], "user_set" => !row[:value].nil?, "value" => row[:value] }
        end
      end

      def apply(settings)
        settings.each { |item| Config.set(item["key"], item["value"].to_s) }
      end

      def restore(priors)
        priors.each do |prior|
          if prior["user_set"]
            Config.set(prior["key"], prior["value"].to_s)
          else
            Config.unset(prior["key"])
          end
        end
      end
    end
  end
end
