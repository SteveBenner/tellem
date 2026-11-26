# frozen_string_literal: true

require_relative "../errors"
require_relative "../ports/harness_paths"
require_relative "../record/fs"
require_relative "../record/schemas"

module Tellem
  module Dashboard
    module Writer
      DIRECTORY = "dashboard"
      PRIVATE_NAME = "dashboard.html"
      SHARE_NAME = "dashboard-share.html"

      Written = Struct.new(:path, :bytes, keyword_init: true)

      module_function

      def write(dataset)
        page = Page.render(dataset)
        directory = File.join(Ports::HarnessPaths.state_dir, DIRECTORY)
        store(directory, File.join(directory, dataset.fetch("share") ? SHARE_NAME : PRIVATE_NAME), page)
      end

      def store(directory, path, page)
        prepare(directory)
        Record::FS.replace(path, page)
        Written.new(path: path, bytes: page.bytesize)
      rescue SystemCallError => e
        raise OperationalFailure.new("the dashboard file could not be written (#{e.class.name})", detail: { "path" => path })
      end

      def prepare(directory)
        Record::FS.mkdir_p(directory, Record::Schemas::DIR_MODE)
        stat = Record::FS.lstat(directory)
        raise SymlinkRefused.new("symlinked dashboard directory refused", detail: { "path" => directory }) if stat.symlink?
        raise OperationalFailure.new("the dashboard directory is not a directory", detail: { "path" => directory }) unless stat.directory?

        File.chmod(Record::Schemas::DIR_MODE, directory)
      end
    end
  end
end
