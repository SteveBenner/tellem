#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT
# frozen_string_literal: true

require "io/wait"
require "json"
require "open3"
require "time"

module Rplugin
  module Adapters
    module Tellem
      module Persona
        class Identity < Rplugin::Ports::Base
          SCHEMA = "persona.session/v1"
          COMMAND = "persona"
          TIMEOUT_S = 3
          MAX_BYTES = 4_194_304
          HARNESSES = %w[claude codex].freeze
          SESSION_ID = /\A[A-Za-z0-9_-]{1,200}\z/
          TRANSITION = /(?:^|[;&|(`])[ \t]*persona[ \t]+(status|load|lead|unload)(?![A-Za-z0-9_-])([^;&|()`\n]*)/
          HELP_FLAGS = %w[-h --help].freeze

          def self.command_available?
            ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? do |dir|
              path = File.join(dir, COMMAND)
              File.file?(path) && File.executable?(path)
            end
          end

          def snapshot(harness:, session_id:)
            degrade(:snapshot, harness: harness, session_id: session_id) do
              sample(harness.to_s, session_id.to_s)
            end
          end

          def from_tool_result(text:, at:)
            degrade(:from_tool_result, text: text, at: at) do
              evidence(text, at, "transcript_observed")
            end
          end

          def transition_command?(command)
            return false unless command.is_a?(String)

            command.scan(TRANSITION).any? do |_verb, rest|
              rest.split.none? { |token| HELP_FLAGS.include?(token) }
            end
          end

          private

          def sample(harness, session_id)
            return :unknown unless HARNESSES.include?(harness) && SESSION_ID.match?(session_id)
            return :unknown unless self.class.command_available?

            at = Time.now.utc
            output = run_bounded([COMMAND, "status", "--harness", harness, "--session", session_id])
            return :unknown unless output

            evidence(output, at, "sampled") || :unknown
          end

          def evidence(text, at, authority)
            doc = parse(text)
            return nil unless doc && doc["schema"] == SCHEMA && doc["revision"].is_a?(Integer) && doc["members"].is_a?(Array)

            members = doc["members"].map { |member| member_of(member) }
            return nil if members.any?(&:nil?)

            effective_at = stamp(at)
            return nil unless effective_at

            {
              "members" => members,
              "lead" => name_or_nil(doc["lead"]),
              "revision" => doc["revision"],
              "speaker" => name_or_nil(doc["speaker"]),
              "authority" => authority,
              "effective_at" => effective_at
            }
          end

          def member_of(member)
            return nil unless member.is_a?(Hash)

            name = name_or_nil(member["name"])
            return nil unless name

            { "name" => name, "version" => name_or_nil(member["version"]), "digest" => name_or_nil(member["digest"]) }
          end

          def name_or_nil(value)
            value.is_a?(String) && !value.empty? ? value : nil
          end

          def parse(text)
            return nil unless text.is_a?(String) && text.bytesize <= MAX_BYTES

            body = text.strip
            first = body.index("{")
            last = body.rindex("}")
            return nil unless first && last && last > first

            doc = JSON.parse(body[first..last])
            doc.is_a?(Hash) ? doc : nil
          rescue JSON::ParserError, EncodingError
            nil
          end

          def stamp(at)
            time = case at
                   when Time then at
                   when String then Time.iso8601(at)
                   when Integer then Time.at(at)
                   end
            time&.utc&.iso8601(3)
          rescue ArgumentError
            nil
          end

          def clock
            Process.clock_gettime(Process::CLOCK_MONOTONIC)
          end

          def run_bounded(argv)
            deadline = clock + TIMEOUT_S
            Open3.popen2(*argv, err: File::NULL, pgroup: true) do |stdin, stdout, wait|
              stdin.close
              output = read_until(stdout, deadline)
              finished = output && wait.join([deadline - clock, 0].max)
              unless finished
                kill_group(wait.pid)
                next nil
              end
              wait.value.success? ? output : nil
            end
          rescue SystemCallError, IOError
            nil
          end

          def read_until(io, deadline)
            output = +""
            loop do
              remaining = deadline - clock
              return nil if remaining <= 0 || !io.wait_readable(remaining)

              chunk = io.read_nonblock(65_536, exception: false)
              next if chunk == :wait_readable
              return output if chunk.nil?

              output << chunk
              return nil if output.bytesize > MAX_BYTES
            end
          end

          def kill_group(pid)
            Process.kill("KILL", -pid)
          rescue SystemCallError
            nil
          end
        end
      end
    end
  end
end
