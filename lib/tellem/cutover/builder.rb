# frozen_string_literal: true

require_relative "../errors"
require_relative "../record/fs"
require_relative "files"

module Tellem
  module Cutover
    class Builder
      CREATED_MODE = 0o644

      attr_reader :ai_home, :real_home, :notes

      def initialize(ai_home)
        @ai_home = ai_home
        @real_home = ai_home && File.realpath(ai_home)
        @files = {}
        @routes = {}
        @notes = {}
      end

      def edit(route, role, create: false, outside: nil, create_mode: nil)
        path = File.absolute_path?(route) ? route : File.join(ai_home, route)
        located = locate(path, route)
        return unless located

        real, identity = located
        unless inside?(real) || outside == real
          note(route, "resolves to #{real}, outside ~/.ai, and is not a file the harness port names")
          return
        end
        entry = @files[identity] || fresh(real, route, create, create_mode)
        return unless entry

        entry["routes"] |= [route]
        @routes[route] = identity
        text = entry["after"].to_s.dup.force_encoding(Encoding::UTF_8)
        updated, changes = yield(text)
        @files[identity] ||= entry
        return if changes.empty?

        entry["after"] = updated.b
        entry["roles"] |= [role]
        entry["changes"].concat(changes)
      end

      def entry_for(route)
        identity = @routes[route] || identity_of(route)
        entry = identity && @files[identity]
        entry && !entry["changes"].empty? ? entry : nil
      end

      def note(route, reason)
        @notes[route] ||= reason
      end

      def entries
        @files.values.reject { |entry| entry["changes"].empty? }.map { |entry| finish(entry) }.sort_by { |entry| entry["path"] }
      end

      private

      def fresh(real, route, create, create_mode = nil)
        bytes, mode = Files.current(real)
        return nil if bytes.nil? && !create

        rel = inside?(real) ? real.delete_prefix("#{real_home}/") : nil
        { "path" => real, "rel" => rel, "inside_ai_home" => !rel.nil?, "routes" => [], "roles" => [], "changes" => [],
          "before" => bytes, "after" => bytes, "mode" => mode || create_mode || CREATED_MODE }
      rescue SymlinkRefused, OperationalFailure => e
        note(route, e.message)
        nil
      end

      def locate(path, route)
        dir = File.realpath(File.dirname(path))
        real = File.join(dir, File.basename(path))
        stat = Record::FS.lstat(real)
        [real, stat ? "#{stat.dev}:#{stat.ino}" : real]
      rescue SystemCallError => e
        note(route, "cannot resolve: #{e.class.name}")
        nil
      end

      def identity_of(route)
        path = File.absolute_path?(route) ? route : File.join(ai_home, route)
        stat = File.stat(path)
        "#{stat.dev}:#{stat.ino}"
      rescue SystemCallError
        nil
      end

      def inside?(real)
        !real_home.nil? && real.start_with?("#{real_home}/")
      end

      def finish(entry)
        entry.merge("action" => entry["before"].nil? ? "create" : "edit", "before_sha256" => Files.sha256(entry["before"]),
                    "after_sha256" => Files.sha256(entry["after"]))
      end
    end
  end
end
