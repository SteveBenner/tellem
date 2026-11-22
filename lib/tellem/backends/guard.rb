# frozen_string_literal: true

require "json"
require_relative "../config/resolver"
require_relative "../ports/harness_paths"
require_relative "../record/fs"
require_relative "../redact"

module Tellem
  module Backends
    module Guard
      RATE_PER_SECOND = 20.0
      BURST = 40
      MAX_ATTEMPTS = 3
      BACKOFF_BASE_S = 0.25
      BACKOFF_CAP_S = 4.0
      CONNECT_TIMEOUT_S = 3
      STATEMENT_TIMEOUT_MS = 15_000
      BUSY_TIMEOUT_MS = 5000
      BREAKER_THRESHOLD = 5
      BREAKER_OPEN_S = 60
      PROBE_LEASE_S = 30

      Result = Struct.new(:ok, :value, :error_class, :error, :attempts, :breaker, keyword_init: true) do
        def ok?
          ok
        end
      end

      class Limiter
        def initialize(rate: RATE_PER_SECOND, burst: BURST)
          @rate = rate
          @burst = burst.to_f
          @tokens = @burst
          @stamp = monotonic
        end

        def acquire
          refill
          if @tokens < 1.0
            wait = (1.0 - @tokens) / @rate
            sleep(wait)
            refill
          end
          @tokens -= 1.0
        end

        private

        def refill
          now = monotonic
          @tokens = [@burst, @tokens + ((now - @stamp) * @rate)].min
          @stamp = now
        end

        def monotonic
          Process.clock_gettime(Process::CLOCK_MONOTONIC)
        end
      end

      module State
        module_function

        def path
          Ports::HarnessPaths.backend_breaker
        end

        def read(key)
          load_all.fetch(key, nil) || fresh
        rescue SystemCallError, JSON::ParserError
          fresh
        end

        def update(key)
          Record::FS.mkdir_p(File.dirname(path))
          File.open(path, File::RDWR | File::CREAT | File::NOFOLLOW, Record::Schemas::FILE_MODE) do |file|
            file.flock(File::LOCK_EX)
            all = parse(file.read)
            current = all.fetch(key, nil) || fresh
            entry = yield(current.dup)
            return entry if entry == current

            all[key] = entry
            file.rewind
            file.truncate(0)
            Record::FS.write_all(file, "#{JSON.generate(all)}\n")
            file.fsync
            entry
          end
        end

        def load_all
          return {} unless Record::FS.lexists?(path)

          parse(Record::FS.read(path))
        end

        def parse(text)
          data = text.to_s.strip.empty? ? {} : JSON.parse(text)
          data.is_a?(Hash) ? data : {}
        rescue JSON::ParserError
          {}
        end

        def fresh
          { "failures" => 0, "opened_at" => nil, "probe_until" => nil, "last_sync_at" => nil, "last_error" => nil }
        end
      end

      @limiters = {}

      module_function

      def disabled?
        Config.disabled?(:backend)
      end

      def limiter(key)
        @limiters[key] ||= Limiter.new
      end

      def breaker_state(key, now = Time.now.to_f)
        return "disabled" if disabled?

        entry = State.read(key)
        opened = entry["opened_at"]
        return "closed" if opened.nil?

        now - opened.to_f < BREAKER_OPEN_S ? "open" : "half_open"
      end

      def backoff(attempt, random: Random)
        ceiling = [BACKOFF_CAP_S, BACKOFF_BASE_S * (2**(attempt - 1))].min
        random.rand * ceiling
      end

      def run(key, retryable:, sanitize:, on_failure: nil, breaker: true)
        return Result.new(ok: false, error_class: "disabled", error: "TELLEM_BACKEND_DISABLED=1", attempts: [], breaker: "disabled") if disabled?

        log = []
        attempt = 0
        loop do
          admission = breaker ? admit(key) : observe(key)
          unless admission == :allow || admission == :probe
            return Result.new(ok: false, error_class: "breaker_open", error: "circuit breaker open for #{key}", attempts: log,
                              breaker: "open")
          end

          attempt += 1
          limiter(key).acquire
          started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          begin
            value = yield(attempt)
            record_success(key) if breaker
            log << { "attempt" => attempt, "ok" => true, "ms" => elapsed_ms(started) }
            return Result.new(ok: true, value: value, attempts: log, breaker: "closed")
          rescue CapabilityUnavailable => e
            log << { "attempt" => attempt, "ok" => false, "error_class" => e.class.name, "ms" => elapsed_ms(started) }
            return Result.new(ok: false, error_class: e.class.name, error: sanitize.call(e.message.to_s), attempts: log,
                              breaker: breaker_state(key))
          rescue StandardError => e
            on_failure&.call(e)
            state = breaker ? record_failure(key, e.class.name) : breaker_state(key)
            entry = { "attempt" => attempt, "ok" => false, "error_class" => e.class.name, "ms" => elapsed_ms(started),
                      "breaker" => state }
            message = sanitize.call(e.message.to_s)
            if state == "open" || attempt >= MAX_ATTEMPTS || !retryable.call(e)
              log << entry
              return Result.new(ok: false, error_class: e.class.name, error: message, attempts: log, breaker: state)
            end

            delay = backoff(attempt)
            entry["delay_ms"] = (delay * 1000).round
            log << entry
            sleep(delay)
          end
        end
      end

      def admit(key)
        verdict = :allow
        State.update(key) do |entry|
          now = Time.now.to_f
          opened = entry["opened_at"]
          if opened.nil?
            entry
          elsif now - opened.to_f < BREAKER_OPEN_S
            verdict = :reject
            entry
          elsif entry["probe_until"] && entry["probe_until"].to_f > now
            verdict = :reject
            entry
          else
            verdict = :probe
            entry.merge("probe_until" => now + PROBE_LEASE_S)
          end
        end
        verdict
      rescue SystemCallError
        :allow
      end

      def observe(key)
        breaker_state(key) == "open" ? :reject : :allow
      end

      def record_success(key)
        State.update(key) do |entry|
          entry.merge("failures" => 0, "opened_at" => nil, "probe_until" => nil, "last_error" => nil)
        end
      rescue SystemCallError
        nil
      end

      def record_failure(key, error_class)
        result = "closed"
        State.update(key) do |entry|
          now = Time.now.to_f
          failures = entry["failures"].to_i + 1
          opened = entry["opened_at"]
          if opened || failures >= BREAKER_THRESHOLD
            result = "open"
            entry.merge("failures" => failures, "opened_at" => now, "probe_until" => nil, "last_error" => error_class)
          else
            entry.merge("failures" => failures, "last_error" => error_class)
          end
        end
        result
      rescue SystemCallError
        result
      end

      def record_sync(key, at)
        State.update(key) { |entry| entry.merge("last_sync_at" => at) }
      rescue SystemCallError
        nil
      end

      def last_sync_at(key)
        State.read(key)["last_sync_at"]
      end

      def failures(key)
        State.read(key)["failures"].to_i
      end

      def sanitizer(*secrets)
        literals = secrets.compact.map(&:to_s).reject(&:empty?).sort_by { |value| -value.length }
        lambda do |message|
          text = message.to_s.dup
          literals.each { |literal| text = text.gsub(literal, "[REDACTED:credential]") }
          Redact.text(text)[0, 500]
        end
      end

      def elapsed_ms(started)
        ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
      end
    end
  end
end
