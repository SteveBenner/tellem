# frozen_string_literal: true

require "rbconfig"
require "socket"
require_relative "../record/fs"
require_relative "../record/schemas"
require_relative "settings"
require_relative "state"

module Tellem
  module Otel
    module Ensure
      LOCK_FLAGS = File::RDWR | File::CREAT | File::NOFOLLOW
      BACKLOG = 128

      module_function

      def run(plugin_root)
        return :off unless Settings.enabled?
        return :running if State.running_pid

        Record::FS.mkdir_p(Settings.dir)
        File.open(Settings.lock_file, LOCK_FLAGS, Record::Schemas::FILE_MODE) do |lock|
          next :starting unless lock.flock(File::LOCK_EX | File::LOCK_NB)

          start(plugin_root, lock)
        end
      end

      def start(plugin_root, lock)
        server = listen(Settings.port)
        return :port_in_use unless server

        spawn(plugin_root, server, lock)
        :spawned
      ensure
        server&.close
      end

      def listen(port)
        server = TCPServer.new(Settings::HOST, port)
        server.listen(BACKLOG)
        server
      rescue Errno::EADDRINUSE, Errno::EACCES => e
        State.merge("state" => "port_in_use", "port" => port, "error_class" => e.class.name, "updated_at" => State.now, "pid" => nil)
        nil
      end

      def spawn(plugin_root, server, lock)
        pid = Process.spawn(RbConfig.ruby, File.join(plugin_root, "bin", "tellem-otel"), "serve", Settings::INHERIT_FLAG,
                            Settings::LISTEN_FD => server, Settings::LOCK_FD => lock,
                            pgroup: true, in: :close, out: File::NULL, err: File::NULL)
        Process.detach(pid)
        pid
      end
    end
  end
end
