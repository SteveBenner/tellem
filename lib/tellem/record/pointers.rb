# frozen_string_literal: true

require "json"
require_relative "formats"
require_relative "fs"
require_relative "scope"
require_relative "writer"

module Tellem
  module Record
    module Pointers
      module_function

      def write(scope_root, pointer)
        record = Formats.pointer(**pointer.transform_keys(&:to_sym))
        Scope.prepare(scope_root)
        Writer.replace_if_changed(Scope.pointer_path(scope_root, record["session_key"]), "#{JSON.generate(record)}\n")
        record
      end

      def read(scope_root, session_key)
        data = JSON.parse(FS.read(Scope.pointer_path(scope_root, session_key)))
        data.is_a?(Hash) && data["schema"] == Schemas::POINTER ? data : nil
      rescue Errno::ENOENT, JSON::ParserError
        nil
      end

      def each(scope_root)
        return enum_for(:each, scope_root) unless block_given?

        names(scope_root).each do |session_key|
          pointer = read(scope_root, session_key)
          yield pointer if pointer
        end
      end

      def names(scope_root)
        Dir.children(Scope.pointers_dir(scope_root)).filter_map do |name|
          key = name.delete_suffix(".json")
          key if name.end_with?(".json") && Ids.valid_session_key?(key)
        end.sort
      rescue SystemCallError
        []
      end

      def gone?(pointer)
        root = pointer["home_root"]
        return true unless root.is_a?(String) && File.directory?(Scope.dir(root))

        !File.directory?(Scope.session_dir(root, pointer["session_key"]))
      end

      def resolve(pointer)
        pointer.merge("gone" => gone?(pointer))
      end
    end
  end
end
