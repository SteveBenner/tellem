# frozen_string_literal: true

require_relative "../errors"
require_relative "../seams"
require_relative "../version"
require_relative "../ports/harness_paths"
require_relative "timeline"

module Tellem
  module Identity
    class Binding
      EXTENSION = "persona"
      PORT = "identity"
      BINDINGS = %w[none auto persona].freeze

      attr_reader :scope

      def initialize(scope: nil)
        @scope = scope
      end

      def for_scope(scope_root)
        self.class.new(scope: scope_root)
      end

      def foundation_default?
        false
      end

      def available?
        true
      end

      def snapshot(harness:, session_id:)
        port.snapshot(harness: harness, session_id: session_id)
      end

      def from_tool_result(text:, at:)
        port.from_tool_result(text: text, at: at)
      end

      def transition_command?(command)
        return false unless command.is_a?(String)

        current = detector
        current ? current.transition_command?(command) == true : false
      rescue StandardError, ScriptError
        false
      end

      def evidence_from(persona_results)
        Timeline.evidence_from(persona_results, self)
      end

      def attribute(observations, evidence)
        Timeline.attribute(observations, evidence).map { |ref| Timeline.usage_attribution(ref) }
      end

      def status
        ext = extension
        {
          "binding" => binding,
          "enabled" => enabled?,
          "extension" => ext ? ext.dir : nil,
          "detected" => ext ? ext.detected? : false,
          "adapter" => adapter_name
        }
      end

      def binding
        value = setting("persona.binding")
        BINDINGS.include?(value) ? value : "auto"
      end

      def enabled?
        setting("features.persona") == true
      end

      def port
        @port ||= resolve
      end

      private

      def resolve
        return Seams::UnknownIdentity.new unless rplugin? && enabled?

        case binding
        when "none" then Seams::UnknownIdentity.new
        when "persona" then forced || standalone
        else Rplugin::Ports.for(Ports::HarnessPaths::PLUGIN_ID, root: Tellem.root).public_send(PORT)
        end
      end

      def adapter_name
        current = port
        current.respond_to?(:adapter_names) ? current.adapter_names.first : current.class.name
      end

      def detector
        return @detector if defined?(@detector)

        @detector = detect
      end

      def detect
        ext = rplugin? ? extension : nil
        found = ext && ext.detected? ? forced : nil
        found.respond_to?(:transition_command?) ? found : nil
      rescue StandardError, ScriptError
        nil
      end

      def forced
        ext = extension
        file = ext && ext.adapter_file(PORT)
        return nil unless file

        require file
        klass = Object.const_get(["Rplugin", "Adapters", camelize(Ports::HarnessPaths::PLUGIN_ID), camelize(ext.id), camelize(PORT)].join("::"))
        klass.new(plugin_id: Ports::HarnessPaths::PLUGIN_ID, fallback: standalone, root: Tellem.root)
      rescue NameError, LoadError
        nil
      end

      def standalone
        require_relative "../ports/identity"
        Ports::Identity.new(plugin_id: Ports::HarnessPaths::PLUGIN_ID, root: Tellem.root)
      end

      def extension
        return nil unless rplugin?

        Rplugin::Extensions.local(Tellem.root).find { |ext| ext.id == EXTENSION }
      end

      def setting(key)
        return nil unless rplugin?

        Config.get(key, scope: scope)
      rescue Tellem::Error, Rplugin::Error
        nil
      end

      def rplugin?
        defined?(Rplugin::Ports::Base) && defined?(Rplugin::Extensions) && defined?(Tellem::Config) ? true : false
      end

      def camelize(text)
        text.to_s.split(/[-_]/).map { |part| part[0].upcase + part[1..].to_s }.join
      end
    end
  end
end
