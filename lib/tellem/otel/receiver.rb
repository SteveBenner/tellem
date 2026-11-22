# frozen_string_literal: true

require "json"
require "socket"
require "stringio"
require "zlib"
require_relative "../record/fs"
require_relative "../record/hook_core"
require_relative "../record/schemas"
require_relative "extract"
require_relative "settings"
require_relative "state"

module Tellem
  module Otel
    class Receiver
      BODY_BYTES = 1_048_576
      HEADER_BYTES = 16_384
      IDLE_S = 1800
      IO_TIMEOUT_S = 5
      NESTING = 64
      PATH = "/v1/logs"
      STATUS = {
        200 => "OK", 400 => "Bad Request", 401 => "Unauthorized", 404 => "Not Found", 405 => "Method Not Allowed",
        408 => "Request Timeout", 411 => "Length Required", 413 => "Content Too Large", 415 => "Unsupported Media Type"
      }.freeze

      class Refused < StandardError
        attr_reader :status, :cause

        def initialize(status, cause)
          @status = status
          @cause = cause
          super(cause)
        end
      end

      def self.serve(token:, inherited: false)
        new(port: Settings.port, token: token, inherited: inherited).run
      end

      def initialize(port:, token:, inherited: false)
        @port = port
        @token = token.to_s
        @inherited = inherited
        @state = State.read.slice(*State::COUNTERS, "refused", "last_request_at", "last_event_at")
        @state["refused"] = @state["refused"].is_a?(Hash) ? @state["refused"] : {}
        State::COUNTERS.each { |name| @state[name] = @state[name].to_i }
      end

      def run
        Record::FS.mkdir_p(Settings.dir)
        lock = open_lock
        return :busy unless lock.flock(File::LOCK_EX | File::LOCK_NB)
        return finish("no_token") if @token.empty?

        server = @inherited ? adopt : bind
        return :port_in_use unless server

        Record::FS.replace(Settings.pid_file, "#{Process.pid}\n")
        publish("running", "started_at" => State.now)
        loop_until_idle(server)
        finish("idle_exit")
      ensure
        server&.close
        lock&.close
      end

      def open_lock
        return File.for_fd(Settings::LOCK_FD, autoclose: true) if @inherited

        File.open(Settings.lock_file, File::RDWR | File::CREAT | File::NOFOLLOW, Record::Schemas::FILE_MODE)
      end

      def bind
        TCPServer.new(Settings::HOST, @port)
      rescue Errno::EADDRINUSE, Errno::EACCES => e
        finish("port_in_use", "error_class" => e.class.name)
        nil
      end

      def adopt
        server = TCPServer.for_fd(Settings::LISTEN_FD)
        address = server.local_address
        raise ArgumentError, "inherited socket is not on #{Settings::HOST}" unless address.ip_address == Settings::HOST

        @port = address.ip_port
        server
      rescue SystemCallError, SocketError, ArgumentError => e
        server&.close
        finish("inherit_failed", "error_class" => e.class.name)
        nil
      end

      def loop_until_idle(server)
        deadline = monotonic + IDLE_S
        loop do
          remaining = deadline - monotonic
          break if remaining <= 0
          next unless server.wait_readable(remaining)

          client = accept(server)
          next unless client

          deadline = monotonic + IDLE_S
          handle(client)
        end
      end

      def accept(server)
        server.accept_nonblock
      rescue IO::WaitReadable, Errno::EINTR, Errno::ECONNABORTED
        nil
      end

      def handle(client)
        @state["requests"] += 1
        @state["last_request_at"] = State.now
        status = process(client)
        respond(client, status)
      rescue Refused => e
        refuse(e.cause)
        respond(client, e.status)
      rescue StandardError
        refuse("bad_request")
        respond(client, 400)
      ensure
        client.close
        publish("running")
      end

      def process(client)
        method, path, headers = read_head(client)
        raise Refused.new(404, "not_found") unless path == PATH
        raise Refused.new(405, "method_not_allowed") unless method == "POST"
        raise Refused.new(401, "unauthorized") unless authorized?(headers["authorization"])
        raise Refused.new(411, "length_required") if headers.key?("transfer-encoding") || !headers["content-length"].to_s.match?(/\A\d{1,12}\z/)

        length = Integer(headers["content-length"], 10)
        raise Refused.new(413, "too_large") if length > BODY_BYTES
        raise Refused.new(415, "unsupported_media") unless headers["content-type"].to_s.downcase.start_with?("application/json")

        body = inflate(read_exact(client, length), headers["content-encoding"]).dup.force_encoding(Encoding::UTF_8)
        document = JSON.parse(body, max_nesting: NESTING)
        keep(document)
        200
      rescue JSON::ParserError, EncodingError
        raise Refused.new(400, "bad_request")
      end

      def keep(document)
        kept, refused, ignored = Extract.events(document)
        refused.each { |cause, count| refuse(cause, count) }
        @state["events_ignored"] += ignored
        kept.group_by { |event| event["session_id"] }.each do |session_id, events|
          path = Settings.spool("claude-#{session_id}")
          events.each { |event| Record::HookCore.append(path, JSON.generate(event), sync: false) }
        end
        return if kept.empty?

        @state["events_kept"] += kept.size
        @state["last_event_at"] = State.now
      end

      def authorized?(value)
        expected = "Bearer #{@token}"
        given = value.to_s
        return false unless given.bytesize == expected.bytesize

        given.bytes.zip(expected.bytes).reduce(0) { |acc, (a, b)| acc | (a ^ b) }.zero?
      end

      def inflate(body, encoding)
        case encoding.to_s.strip.downcase
        when "", "identity" then body
        when "gzip"
          inflated = Zlib::GzipReader.new(StringIO.new(body)).read(BODY_BYTES + 1).to_s
          raise Refused.new(413, "too_large") if inflated.bytesize > BODY_BYTES

          inflated
        else raise Refused.new(415, "unsupported_encoding")
        end
      rescue Zlib::Error
        raise Refused.new(400, "bad_request")
      end

      def read_head(client)
        buffer = String.new
        until (stop = buffer.index("\r\n\r\n"))
          raise Refused.new(400, "bad_request") if buffer.bytesize > HEADER_BYTES

          buffer << read_some(client, HEADER_BYTES)
        end
        @leftover = buffer.byteslice(stop + 4..)
        lines = buffer.byteslice(0, stop).split("\r\n")
        method, path, = lines.shift.to_s.split(" ", 3)
        headers = lines.each_with_object({}) do |line, out|
          key, value = line.split(":", 2)
          out[key.to_s.strip.downcase] = value.to_s.strip if value
        end
        [method, path.to_s.split("?", 2).first, headers]
      end

      def read_exact(client, length)
        body = @leftover.to_s.byteslice(0, length).to_s.b
        body << read_some(client, length - body.bytesize) while body.bytesize < length
        body
      end

      def read_some(client, max)
        chunk = client.read_nonblock(max, exception: false)
        if chunk == :wait_readable
          raise Refused.new(408, "timeout") unless client.wait_readable(IO_TIMEOUT_S)

          return read_some(client, max)
        end
        raise Refused.new(400, "bad_request") if chunk.nil?

        chunk
      end

      def respond(client, status)
        body = status == 200 ? "{}" : JSON.generate("error" => STATUS.fetch(status, "Error"))
        client.write("HTTP/1.1 #{status} #{STATUS.fetch(status, 'Error')}\r\nContent-Type: application/json\r\n" \
                     "Content-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}")
      rescue SystemCallError, IOError
        nil
      end

      def refuse(cause, count = 1)
        @state["refused"][cause] = @state["refused"][cause].to_i + count
      end

      def publish(state, extra = {})
        current = State.read
        current = current.reject { |key, _| State::ERROR_KEYS.include?(key) } if state == "running"
        State.write(current.merge(@state).merge("state" => state, "pid" => Process.pid, "port" => @port, "updated_at" => State.now).merge(extra))
      end

      def finish(state, extra = {})
        Record::FS.unlink_quiet(Settings.pid_file) if State.pid == Process.pid
        publish(state, extra.merge("pid" => nil))
        state.to_sym
      end

      def monotonic
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
