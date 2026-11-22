# frozen_string_literal: true

require "json"
require_relative "../errors"

module Tellem
  module Config
    module Tasks
      PREFIX = "tasks."
      SCHEMA = {
        "marker" => :str,
        "new_threshold" => :num,
        "idle_points" => :pairs,
        "closing_points" => :num,
        "repo_points" => :num,
        "clear_points" => :num,
        "overlap_low" => :num,
        "overlap_low_points" => :num,
        "overlap_high" => :num,
        "overlap_high_points" => :num,
        "overlap_min_tokens" => :num,
        "link_entrypoints" => :strs,
        "continuation_max_words" => :num,
        "continuation_openers" => :strs,
        "continuation_points" => :num,
        "question_points" => :num,
        "question_cues" => :strs,
        "workflow_commands" => :strs,
        "link_window_minutes" => :num,
        "link_min_overlap" => :num,
        "autoclose_hours" => :num,
        "display_elapsed" => :display
      }.freeze
      PROMPTS_KEY = "system_prompts"
      DISPLAY = %w[freeze now].freeze
      JSON_DEPTH = 4

      module_function

      def number?(value)
        (value.is_a?(Integer) || value.is_a?(Float)) && (!value.is_a?(Float) || value.finite?)
      end

      def valid?(kind, value)
        case kind
        when :str then value.is_a?(String) && !value.empty?
        when :num then number?(value)
        when :strs then value.is_a?(Array) && value.all?(String)
        when :display then DISPLAY.include?(value)
        else value.is_a?(Array) && value.all? { |item| item.is_a?(Array) && item.length == 2 && item.all? { |part| number?(part) } }
        end
      end

      def kind_of_key(key)
        return :strs if key == PROMPTS_KEY

        SCHEMA[key]
      end

      def setting?(setting_key)
        setting_key.start_with?(PREFIX) && !kind_of_key(setting_key.delete_prefix(PREFIX)).nil?
      end

      def reject!(setting_key)
        raise UsageError.new("bad tasks config key: #{setting_key}", next_command: "tellem config get #{setting_key}",
                             detail: { "key" => setting_key })
      end

      def decode(setting_key, raw)
        kind = kind_of_key(setting_key.delete_prefix(PREFIX))
        value = if %i[str display].include?(kind)
                  raw
                else
                  raise ArgumentError unless raw.is_a?(String)

                  JSON.parse(raw, max_nesting: JSON_DEPTH)
                end
        reject!(setting_key) unless valid?(kind, value)
        value
      rescue JSON::ParserError, ArgumentError
        reject!(setting_key)
      end

      def validate_text!(setting_key, text)
        decode(setting_key, text)
        text
      end

      def rules(settings)
        SCHEMA.keys.to_h do |key|
          name = "#{PREFIX}#{key}"
          [key, decode(name, settings.get(name))]
        end
      end

      def system_prompts(settings)
        name = "#{PREFIX}#{PROMPTS_KEY}"
        decode(name, settings.get(name))
      end
    end
  end
end
