# frozen_string_literal: true

require_relative "../seams"
require_relative "claude"
require_relative "codex"
require_relative "../transcript/markdown"

Tellem::Seams.register(:ingest_claude, Tellem::Ingest::Claude)
Tellem::Seams.register(:ingest_codex, Tellem::Ingest::Codex)
Tellem::Seams.register(:markdown, Tellem::Transcript::Markdown)
