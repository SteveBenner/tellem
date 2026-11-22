# frozen_string_literal: true

require "etc"
require "json"
require_relative "../backends/rows"
require_relative "../errors"
require_relative "../otel/report_details"
require_relative "../record/formats"
require_relative "../record/fs"
require_relative "../record/kinds"
require_relative "records"

module Tellem
  module Reports
    module Scan
      MAX_WORKERS = 8
      INLINE_BYTES = 4 * 1024 * 1024
      NULL_SUPERSEDES = '"supersedes":null'
      TOP = %w[id ts session_key agent_key].freeze
      UNIQUE = %w[id ts].freeze

      Job = Struct.new(:index, :path, :bytes)

      module_function

      def keep?(line)
        line.include?("usage") || (line.include?("supersedes") && !line.include?(NULL_SUPERSEDES))
      end

      def usage_file(path, columns)
        tuples = []
        supersedes = []
        details = {}
        strings = {}
        Records.each_line_record(path, keep: method(:keep?)) do |record|
          next unless Record::Formats.derived_valid?(record)

          supersedes << record["supersedes"] if record["supersedes"]
          kind = record["kind"]
          if kind == "usage"
            tuples << tuple(record, columns, strings)
          elsif kind == Backends::Rows::DETAIL_KIND
            Otel::ReportDetails.remember(details, record)
          end
        end
        [tuples, supersedes, details.to_a]
      end

      def tuple(record, columns, strings)
        body = record["body"] || {}
        columns.map do |name|
          if TOP.include?(name)
            value = record[name]
            UNIQUE.include?(name) || !value.is_a?(String) ? value : (strings[value] ||= value)
          elsif Record::Kinds::COUNTERS.include?(name)
            integer(body[name])
          else
            value = text(body[name])
            value.nil? ? nil : (strings[value] ||= value)
          end
        end
      end

      def earlier?(tuple, current, ts, session)
        ([tuple[ts].to_s, tuple[session].to_s] <=> [current[ts].to_s, current[session].to_s]).negative?
      end

      def text(value)
        value.is_a?(String) ? value : nil
      end

      def integer(value)
        value.is_a?(Integer) ? value : nil
      end

      def run(paths, columns, workers: nil)
        jobs = paths.each_with_index.map { |path, index| Job.new(index, path, Record::FS.lstat(path)&.size.to_i) }
        count = workers || worker_count(jobs)
        results = count <= 1 ? inline(jobs, columns) : forked(jobs, count, columns)
        results.sort_by(&:first).map { |(_index, tuples, supersedes, details)| [tuples, supersedes, details] }
      end

      def worker_count(jobs)
        return 1 unless Process.respond_to?(:fork)
        return 1 if jobs.size < 2 || jobs.sum(&:bytes) < INLINE_BYTES

        [Etc.nprocessors, MAX_WORKERS, jobs.size].min
      end

      def inline(jobs, columns)
        jobs.map { |job| [job.index, *usage_file(job.path, columns)] }
      end

      def forked(jobs, count, columns)
        loads = Array.new(count, 0)
        shares = Array.new(count) { [] }
        jobs.sort_by { |job| [-job.bytes, job.index] }.each do |job|
          slot = loads.each_with_index.min.last
          shares[slot] << job
          loads[slot] += job.bytes
        end
        spawned = shares.reject(&:empty?).map { |share| spawn(share, columns) }
        spawned.flat_map { |(pid, reader)| collect(pid, reader) }
      end

      def spawn(share, columns)
        reader, writer = IO.pipe
        reader.binmode
        writer.binmode
        pid = Process.fork do
          reader.close
          status = 0
          begin
            writer.write(JSON.generate(inline(share, columns)))
          rescue StandardError
            status = 1
          ensure
            writer.close
          end
          Process.exit!(status)
        end
        writer.close
        [pid, reader]
      end

      def collect(pid, reader)
        bytes = reader.read
        reader.close
        _, status = Process.wait2(pid)
        unless status.success? && !bytes.empty?
          raise OperationalFailure.new("a report worker failed (#{status.exitstatus.inspect})", next_command: "tellem health")
        end

        JSON.parse(bytes.force_encoding(Encoding::UTF_8))
      end
    end
  end
end
