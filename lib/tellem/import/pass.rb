# frozen_string_literal: true

require_relative "../deriver/run"
require_relative "../deriver/pass"
require_relative "../deriver/sources"
require_relative "../deriver/lifecycle"

module Tellem
  module Import
    class Pass < Deriver::Pass
      def initialize(root, timer, totals, candidates)
        super(root, timer, totals)
        @candidates = candidates
      end

      def run
        context = Deriver::Context.new(@root)
        sessions = @timer.phase("raw") { @candidates.map { |candidate| session(context, candidate) } }
        sessions.each { |session| @totals.session(session.key) }
        STEPS.each do |name, step|
          @timer.phase(name) do
            sessions.each { |session| guarded(session, name) { step.call(session) } }
            if name == "transcripts"
              sessions.each { |session| guarded(session, name) { @rendered[session.key] = Deriver::Transcripts.render(session) } }
              sessions.each { |session| guarded(session, "entries") { Deriver::Entries.derive(session) } }
              sessions.each { |session| guarded(session, name) { Deriver::Lifecycle.mark_import(session) } }
            end
            flush(sessions)
          end
        end
        @timer.phase("pointers") { pointers(sessions) }
        @timer.phase("registry") { registry(context, sessions) }
        @timer.phase("projections") { projections(context) }
        @timer.phase("mirror") { mirror(context, sessions) }
        sessions
      end

      def session(context, candidate)
        session = Deriver::Session.new(context, candidate.session_key)
        session.natives.merge!(Deriver::Sources.discover(context, candidate.harness, candidate.session_id, candidate.data["main"]))
        session
      end
    end
  end
end
