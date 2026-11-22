# frozen_string_literal: true

require "etc"
require "open3"
require_relative "bounds"
require_relative "records"
require_relative "toml"

module Tellem
  module Discovery
    module Incumbent
      TOOL = "specstory"
      STARTUP = %w[.bashrc .zshrc .profile .bash_profile].freeze
      FUNCTION = /\A\s*(?:function\s+)?([A-Za-z_][\w.-]*)\s*\(\s*\)\s*(\{)?/.freeze
      FISH_FUNCTION = /\A\s*function\s+([A-Za-z_][\w.-]*)/.freeze
      ALIAS = /\A\s*alias\s+([A-Za-z_][\w.-]*)(?:=|\s+)(.*?)\s*\z/.freeze
      RUNS = /\bspecstory\s+(?:run|watch)\s+([A-Za-z][\w-]*)/.freeze
      CRON_BOUND = 3
      PROC_ARGV = 6
      LINK_HOOK = "post-checkout"
      SPECSTORY_DIR = ".specstory"

      module_function

      def wrappers(ctx, deadline)
        files(ctx.paths).flat_map do |path|
          Bounds.check!(deadline, "startup files")
          scan_startup(path)
        end.then { |found| found.empty? ? [absent("wrapper", "startup files")] : found }
      end

      def files(paths)
        home = paths[:home]
        fish = File.join(paths[:config_home], "fish")
        listed = STARTUP.map { |name| File.join(home, name) } + [File.join(fish, "config.fish")]
        listed + Bounds.children(File.join(fish, "conf.d")).grep(/\.fish\z/).map { |name| File.join(fish, "conf.d", name) }
      end

      def absent(kind, label)
        Records.item(id: "#{kind}:#{label}", kind: kind, state: "absent", known_by: "table")
      end

      def scan_startup(path)
        text = Bounds.text(path)
        return [] unless text&.include?(TOOL)

        real = Bounds.real(path)
        lines = text.lines
        blocks(lines, path.end_with?(".fish")).filter_map do |block|
          body = lines[(block[:from] - 1)..(block[:to] - 1)].join
          next unless body.match?(/\b#{TOOL}\b/)

          Records.item(
            id: "wrapper:#{path}:#{block[:name]}", kind: "wrapper", known_by: "table",
            facts: { "file" => path, "real_path" => real, "symlink" => Bounds.lstat(path)&.symlink? == true, "name" => block[:name], "shape" => block[:shape],
                     "lines" => [block[:from], block[:to]], "runs" => body.scan(RUNS).flatten.uniq.sort, "text" => Records.clean(body.lines.find { |line| line.include?(TOOL) }) }
          )
        end
      end

      def blocks(lines, fish)
        found = []
        index = 0
        while index < lines.length
          line = lines[index]
          if (match = ALIAS.match(line))
            found << { name: match[1], shape: "alias", from: index + 1, to: index + 1 }
          elsif fish && (match = FISH_FUNCTION.match(line))
            stop = lines[index..].index { |candidate| candidate.match?(/\A\s*end\b/) } || 0
            found << { name: match[1], shape: "function", from: index + 1, to: index + stop + 1 }
          elsif !fish && (match = FUNCTION.match(line))
            stop = brace_end(lines, index)
            found << { name: match[1], shape: "function", from: index + 1, to: stop + 1 }
            index = stop
          end
          index += 1
        end
        found
      end

      def brace_end(lines, start)
        depth = 0
        opened = false
        (start...lines.length).each do |index|
          code = lines[index].sub(/(?:\A|\s)#.*\z/, "")
          depth += code.count("{")
          opened ||= code.include?("{")
          depth -= code.count("}")
          return index if opened && depth <= 0
        end
        start
      end

      def process_home(pid)
        data = File.open("/proc/#{pid}/environ", "rb") { |io| io.read(256 * 1024) }
        line = data.to_s.split("\0").find { |item| item.start_with?("HOME=") }
        line&.delete_prefix("HOME=")
      rescue SystemCallError, IOError
        nil
      end

      def processes(ctx, deadline)
        here = File.expand_path(ctx.paths[:home].to_s)
        found = Bounds.children("/proc").grep(/\A\d+\z/).filter_map do |pid|
          Bounds.check!(deadline, "process list")
          argv = cmdline(pid)
          next unless argv && File.basename(argv.first.to_s) == TOOL && %w[run watch].include?(argv[1])

          home = process_home(pid)
          next if home && File.expand_path(home) != here

          Records.item(id: "process:#{TOOL}:#{argv[1]}:#{argv[2]}", kind: "process", known_by: "table",
                       facts: { "verb" => argv[1], "agent" => argv[2] }, stats: { "pids" => [pid.to_i] })
        end
        merged = found.group_by { |entry| entry["id"] }.map do |_id, same|
          same.first.merge("stats" => { "pids" => same.flat_map { |entry| entry["stats"]["pids"] }.sort })
        end
        merged.empty? ? [absent("process", TOOL)] : merged
      end

      def cmdline(pid)
        data = File.open("/proc/#{pid}/cmdline", "rb") { |io| io.read(4096) }
        data&.split("\0", PROC_ARGV + 1)&.first(PROC_ARGV)
      rescue SystemCallError, IOError
        nil
      end

      def schedules(ctx, deadline)
        units = File.join(ctx.paths[:config_home], "systemd", "user")
        found = Bounds.children(units).filter_map do |name|
          Bounds.check!(deadline, "systemd units")
          text = Bounds.text(File.join(units, name), limit: 64 * 1024)
          line = text&.lines&.find { |candidate| candidate.include?(TOOL) }
          next unless line

          Records.item(id: "schedule:systemd:#{name}", kind: "schedule", known_by: "table",
                       facts: { "unit" => name, "path" => File.join(units, name), "text" => Records.clean(line) })
        end
        found += crontab(ctx.paths)
        found.empty? ? [absent("schedule", TOOL)] : found
      end

      def crontab(paths)
        owner = account_home
        unless owner && File.expand_path(owner) == File.expand_path(paths[:home])
          reason = owner ? "crontab belongs to the account, not to the home being examined" : "this user id has no account entry"
          return [Records.item(id: "schedule:crontab", kind: "schedule", state: "unknown", known_by: "unknown", reason: reason)]
        end

        output = run_crontab
        return [Records.item(id: "schedule:crontab", kind: "schedule", state: "unknown", known_by: "unknown", reason: "crontab -l gave no answer in time")] unless output

        output.lines.each_with_index.filter_map do |line, index|
          next unless line.include?(TOOL) && !line.strip.start_with?("#")

          Records.item(id: "schedule:crontab:#{index + 1}", kind: "schedule", known_by: "table", facts: { "text" => Records.clean(line) })
        end
      end

      def account_home
        Etc.getpwuid&.dir
      rescue ArgumentError
        nil
      end

      def run_crontab
        Open3.popen2("crontab", "-l", err: File::NULL, pgroup: true) do |stdin, stdout, wait|
          stdin.close
          if stdout.wait_readable(CRON_BOUND) && wait.join(CRON_BOUND)
            stdout.read(256 * 1024).to_s
          else
            Process.kill("KILL", -wait.pid)
            nil
          end
        end
      rescue SystemCallError, IOError
        nil
      end

      def repo_outputs(ctx, deadline)
        found = Array(ctx.paths[:scopes]).filter_map do |root|
          Bounds.check!(deadline, "scope outputs")
          repo_output(root)
        end
        found.empty? ? [absent("repo_output", "scopes")] : found
      end

      def repo_output(root)
        dir = File.join(root, SPECSTORY_DIR)
        info = Bounds.lstat(dir)
        hook = post_checkout(root)
        return nil unless info || hook

        facts = { "root" => root }
        if info
          facts["shape"] = info.symlink? ? "symlink" : (info.directory? ? "directory" : "file")
          if info.symlink?
            facts["target"] = File.readlink(dir)
            facts["target_exists"] = !Bounds.real(dir).nil?
          end
        end
        facts["post_checkout"] = hook if hook
        Records.item(id: "repo_output:#{root}", kind: "repo_output", known_by: "table", facts: facts)
      rescue SystemCallError
        Records.item(id: "repo_output:#{root}", kind: "repo_output", state: "unknown", known_by: "unknown", reason: "link could not be read")
      end

      def post_checkout(root)
        hooks_dir = hooks_directory(root)
        return nil unless hooks_dir

        path = File.join(hooks_dir, LINK_HOOK)
        text = Bounds.text(path, limit: 128 * 1024)
        line = text&.lines&.find { |candidate| candidate.match?(/specstory/i) && !candidate.strip.start_with?("#") }
        line ? { "path" => path, "text" => Records.clean(line) } : nil
      end

      def hooks_directory(root)
        git = File.join(root, ".git")
        info = Bounds.lstat(git)
        return nil unless info

        gitdir = info.directory? ? git : gitdir_of(git, root)
        return nil unless gitdir

        common = Bounds.text(File.join(gitdir, "commondir"), limit: 4096)&.strip
        common_dir = common ? File.expand_path(common, gitdir) : gitdir
        configured = hooks_path(File.join(common_dir, "config"))
        configured ? File.expand_path(configured, root) : File.join(common_dir, "hooks")
      end

      def gitdir_of(file, root)
        line = Bounds.text(file, limit: 4096)&.lines&.first.to_s
        match = /\Agitdir:\s*(.+?)\s*\z/.match(line)
        match ? File.expand_path(match[1], root) : nil
      end

      def hooks_path(config)
        text = Bounds.text(config, limit: 256 * 1024)
        return nil unless text

        in_core = false
        text.each_line do |line|
          in_core = Regexp.last_match(1).casecmp?("core") if line =~ /\A\s*\[\s*([A-Za-z]+)[\s\]"]/
          match = /\A\s*hooksPath\s*=\s*(.+?)\s*\z/i.match(line)
          return match[1].delete('"') if in_core && match
        end
        nil
      end

      def state(ctx, _deadline)
        home = ctx.paths[:specstory_home]
        info = Bounds.stat(home)
        return [Records.item(id: "specstory_state:home", kind: "specstory_state", state: "absent", known_by: "table", facts: { "path" => home })] unless info&.directory?

        config = Bounds.text(File.join(home, "cli", "config.toml"), limit: 128 * 1024)
        entries = config ? Toml.entries(config) : []
        facts = { "path" => home, "cloud_sync_enabled" => toggle(entries, "cloud_sync"), "local_sync_enabled" => toggle(entries, "local_sync"),
                  "config_read" => !config.nil? }
        stats = { "database_bytes" => Bounds.stat(File.join(home, "sessions.db"))&.size }
        [Records.item(id: "specstory_state:home", kind: "specstory_state", known_by: "table", facts: facts, stats: stats)]
      end

      def toggle(entries, section)
        found = entries.find { |entry| entry[:section] == [section] && entry[:key] == "enabled" }
        found ? found[:value] : "unset"
      end
    end
  end
end
