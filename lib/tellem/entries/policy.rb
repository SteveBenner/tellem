# frozen_string_literal: true

require_relative "../version"
require_relative "../ports/harness_paths"

module Tellem
  module Entries
    module Policy
      PORT = "transcript_policy"
      BOUND_S = 3
      READER_ID = /\A[A-Za-z0-9_.-]{1,64}\z/.freeze
      MAX_ITEMS = 1024
      MAX_BYTES = 4096

      Result = Struct.new(:tools, :paths, :readers, :failure, keyword_init: true) do
        def failed?
          !failure.nil?
        end

        def empty?
          tools.empty? && paths.empty?
        end

        def path_withheld?(path, cwd)
          return false if paths.empty?

          Policy.candidates(path, cwd).any? do |candidate|
            paths.any? { |prefix| candidate == prefix || candidate.start_with?(prefix == "/" ? "/" : "#{prefix}/") }
          end
        end
      end

      REUSE_S = 5

      @cached = nil

      module_function

      def resolve(_owner = nil)
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        return @cached[1] if @cached && now - @cached[0] < REUSE_S

        result = evaluate
        @cached = [Process.clock_gettime(Process::CLOCK_MONOTONIC), result]
        result
      end

      def evaluate
        port = Rplugin::Ports.for(Ports::HarnessPaths::PLUGIN_ID, root: Tellem.root).public_send(PORT)
        outcome = bounded { [port.withhold_tools, port.withhold_paths, port.native_readers] }
        return failed("timeout") if outcome == :timeout

        shaped(*outcome)
      rescue StandardError, ScriptError => e
        failed("raised", e.class.name)
      end

      def bounded(&block)
        thread = Thread.new do
          Thread.current.report_on_exception = false
          block.call
        end
        return thread.value if thread.join(BOUND_S)

        thread.kill
        :timeout
      end

      def shaped(tools, paths, readers)
        return failed("shape") unless list?(tools) && list?(paths) && list?(readers)
        return failed("shape") unless tools.all? { |name| name.is_a?(String) && !name.empty? && name.bytesize <= 128 && !name.include?("\0") }
        return failed("shape") unless readers.all? { |id| id.is_a?(String) && READER_ID.match?(id) }
        return failed("shape") unless paths.all? { |path| path.is_a?(String) && path.start_with?("/") && path.bytesize <= MAX_BYTES && !path.include?("\0") }

        Result.new(tools: tools.uniq.freeze, paths: paths.map { |path| normalize(path) }.uniq.freeze, readers: readers.uniq.freeze, failure: nil)
      end

      def list?(value)
        value.is_a?(Array) && value.size <= MAX_ITEMS
      end

      def failed(reason, error_class = nil)
        detail = { "reason" => reason }
        detail["error_class"] = error_class if error_class
        Result.new(tools: [].freeze, paths: [].freeze, readers: [].freeze, failure: detail)
      end

      def candidates(path, cwd)
        absolute = File.expand_path(path, cwd.is_a?(String) && cwd.start_with?("/") ? cwd : "/")
        [absolute, real(absolute)].uniq
      rescue ArgumentError
        []
      end

      def normalize(path)
        absolute = File.expand_path(path)
        real(absolute)
      end

      def real(absolute)
        File.realpath(absolute)
      rescue SystemCallError
        parent = File.dirname(absolute)
        return absolute if parent == absolute

        File.join(real(parent), File.basename(absolute))
      end
    end
  end
end
