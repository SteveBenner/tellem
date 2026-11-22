# frozen_string_literal: true

require_relative "../config/resolver"
require_relative "../ids"
require_relative "../record/fs"
require_relative "../record/visibility"
require_relative "context"
require_relative "sources"
require_relative "locations"
require_relative "samples"
require_relative "transcripts"
require_relative "entries"
require_relative "alignment"
require_relative "reach"
require_relative "persona"
require_relative "lifecycle"
require_relative "usage"
require_relative "messages"
require_relative "pointing"
require_relative "../authority/watch"

module Tellem
  module Deriver
    class Pass
      STEPS = [
        ["places", ->(session) { Locations.derive(session) }],
        ["workspace", ->(session) { Samples.derive(session) }],
        ["transcripts", ->(session) { Transcripts.ingest(session) }],
        ["alignment", ->(session) { Alignment.derive(session) }],
        ["remote", ->(session) { Reach.derive(session) }],
        ["persona", ->(session) { Persona.derive(session) }],
        ["lifecycle", lambda { |session|
          Lifecycle.derive(session)
          Usage.derive(session)
        }],
        ["messages", ->(session) { Messages.derive(session) }]
      ].freeze

      def initialize(root, timer, totals)
        @root = root
        @timer = timer
        @totals = totals
        @rendered = {}
        @targets = []
      end

      def run
        @timer.phase("config") { sync_config }
        @timer.phase("authority") { Authority::Watch.before(@totals) }
        context = Context.new(@root)
        sessions = @timer.phase("raw") do
          scanned = Sources.scan(context)
          scanned + Transcripts.unrendered(context, scanned)
        end
        sessions.each { |session| @totals.session(session.key) }
        @timer.phase("raw") { flush(sessions) }
        STEPS.each do |name, step|
          @timer.phase(name) do
            sessions.each { |session| guarded(session, name) { step.call(session) } }
            sessions.each { |session| guarded(session, name) { @rendered[session.key] = Transcripts.render(session) } } if name == "transcripts"
            sessions.each { |session| guarded(session, "entries") { Entries.derive(session) } } if name == "transcripts"
            flush(sessions)
          end
        end
        @timer.phase("pointers") { pointers(sessions) }
        @timer.phase("authority") { Authority::Watch.after(context, sessions, @totals) }
        @timer.phase("registry") { registry(context, sessions) }
        @timer.phase("retention") { Retention.after_registry(context, sessions, @totals) } if defined?(Retention)
        @timer.phase("specstory") { specstory }
        @timer.phase("projections") { projections(context) }
        @timer.phase("mirror") { mirror(context, sessions) }
      end

      def specstory
        require_relative "../specstory/prevent"
        Specstory::Prevent.after_registry(@totals)
      end

      def sync_config
        Config.sync_capture_flag(scope: @root)
        Config.sync_fsync_flag
      rescue StandardError => e
        @totals.errors << { "phase" => "config", "error_class" => e.class.name }
      end

      def guarded(session, phase)
        return if session.failed

        yield
      rescue StandardError => e
        session.failed = phase
        @totals.errors << { "phase" => phase, "session_key" => session.key, "error_class" => e.class.name, "message" => e.message[0, 200] }
        session.gap("derive_error", "derive/#{phase}", agent_key: Ids::MAIN_AGENT, ts: session.first_ts || Record::FS.rfc3339_ms(0),
                                                      detail: { "error_class" => e.class.name })
      end

      def flush(sessions)
        sessions.each { |session| @totals.absorb(session.flush) }
      end

      def pointers(sessions)
        sessions.each do |session|
          guarded(session, "pointers") { @targets.concat(Pointing.derive(session)) }
        end
        flush(sessions)
        @totals.errors.concat(Record::Visibility.reconcile_each([@root] + @targets))
      end

      def registry(context, sessions)
        failures = Pointing.register([@root] + @targets)
        @totals.errors.concat(failures.map { |failure| failure.merge("phase" => "registry") })
        sessions.each do |session|
          next if session.failed

          entry = { "raw" => session.raw_entries, "native" => session.natives,
                    "rendered" => @rendered[session.key] || context.cursor.session(session.key)["rendered"] || {},
                    "unsettled" => session.unsettled }
          context.cursor.update(session.key, entry, session.raw_paths)
        end
        context.cursor.save
      end

      def projections(context)
        return unless context.flag?("features.views")

        context.seam(:projections).refresh(@root)
      rescue StandardError => e
        @totals.errors << { "phase" => "projections", "error_class" => e.class.name }
      end

      def mirror(context, sessions)
        backend = context.seam(:backend)
        return unless backend.respond_to?(:feed)

        result = backend.feed(@root)
        @totals.mirror = result
        failures = result.is_a?(Hash) ? result[:failures].to_i : 0
        return unless failures.positive?

        session = sessions.first
        return unless session

        session.gap("mirror_feed_failed", "mirror/#{context.scope_id}", agent_key: Ids::MAIN_AGENT,
                                                                       ts: session.first_ts || Record::FS.rfc3339_ms(0),
                                                                       detail: { "failures" => failures, "error_class" => result[:error_class] })
        flush(sessions)
      end
    end
  end
end
