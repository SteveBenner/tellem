# frozen_string_literal: true

require "shellwords"
require_relative "errors"

module Tellem
  module Denied
    PATH = / - (.+)\z/m.freeze

    module_function

    def failure(message)
      path = message[PATH, 1]
      return PermissionDenied.new("permission denied", next_command: "tellem health --all", detail: { "message" => message }) unless path

      blocked = first_blocked(path)
      PermissionDenied.new("permission denied: #{blocked}", next_command: "chmod u+rwX #{Shellwords.escape(blocked)}", detail: { "path" => blocked })
    end

    def first_blocked(path)
      above = []
      current = File.dirname(path)
      until current == File.dirname(current)
        above.unshift(current)
        current = File.dirname(current)
      end
      above.find { |dir| File.directory?(dir) && !File.executable?(dir) } || path
    end
  end
end
