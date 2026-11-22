# frozen_string_literal: true

module Tellem
  ROOT = File.expand_path("../..", __dir__)

  VERSION = begin
    File.read(File.join(ROOT, "VERSION")).strip
  rescue SystemCallError
    "unknown"
  end

  def self.root
    ROOT
  end
end
