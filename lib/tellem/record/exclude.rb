# frozen_string_literal: true

require_relative "../ports/harness_paths"
require_relative "fs"

module Tellem
  module Record
    module Exclude
      module_function

      def covers?(path)
        list = roots
        return true if list.nil?
        return false if list.empty?

        list.any? { |root| under?(path, root) }
      end

      def covering(path)
        Array(roots).find { |root| under?(path, root) }
      end

      def under?(path, root)
        text = path.to_s
        text == root || text.start_with?(root.end_with?("/") ? root : "#{root}/")
      end

      def roots
        file = Ports::HarnessPaths.exclude_roots_file
        return [] unless FS.lexists?(file)

        FS.read(file).lines.map(&:chomp).reject(&:empty?)
      rescue Errno::ENOENT, Errno::ENOTDIR
        []
      rescue StandardError
        nil
      end

      def unreadable?
        roots.nil?
      end
    end
  end
end
