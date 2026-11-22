# frozen_string_literal: true

require_relative "../record/fs"
require_relative "args"
require_relative "targets"

module Tellem
  module Places
    module Ops
      DOCKER_SHORT = "Hcl"
      DOCKER_LONG = %w[host context config log-level tlscacert tlscert tlskey].freeze
      DOCKER_EXEC_SHORT = "euw"
      DOCKER_EXEC_LONG = %w[env env-file user workdir detach-keys].freeze
      DOCKER_RUN_SHORT = "aceEhlmpuvw"
      DOCKER_RUN_LONG = %w[
        add-host annotation attach blkio-weight blkio-weight-device cap-add cap-drop cgroup-parent cgroupns cidfile
        cpu-period cpu-quota cpu-rt-period cpu-rt-runtime cpu-shares cpus cpuset-cpus cpuset-mems device
        device-cgroup-rule device-read-bps device-read-iops device-write-bps device-write-iops detach-keys dns
        dns-option dns-search domainname entrypoint env env-file expose gpus group-add health-cmd health-interval
        health-retries health-start-interval health-start-period health-timeout hostname ip ip6 ipc isolation
        kernel-memory label label-file link link-local-ip log-driver log-opt mac-address memory memory-reservation
        memory-swap memory-swappiness mount name network network-alias oom-score-adj pid pids-limit platform publish
        pull restart runtime security-opt shm-size stop-signal stop-timeout storage-opt sysctl tmpfs ulimit user
        userns uts volume volume-driver volumes-from workdir cpu-count cpu-percent io-maxbandwidth io-maxiops
      ].freeze
      KUBECTL_SHORT = "nsclfoLpv"
      KUBECTL_LONG = %w[
        context namespace cluster kubeconfig server user token as as-group as-uid certificate-authority
        client-certificate client-key request-timeout selector output filename container field-selector template
        sort-by tls-server-name cache-dir profile profile-output vmodule log-dir pod-running-timeout image
      ].freeze
      KUBECTL_LOCAL = %w[config completion kustomize plugin help options].freeze
      KUBECTL_TARGETED = %w[exec attach logs port-forward debug].freeze
      GIT_SHORT = "Cc"
      GIT_LONG = %w[git-dir work-tree namespace config-env super-prefix attr-source].freeze
      GIT_COMMANDS = {
        "push" => { short: "o", long: %w[repo push-option receive-pack exec] },
        "fetch" => { short: "jo", long: %w[depth deepen shallow-since shallow-exclude upload-pack jobs negotiation-tip server-option refmap filter submodule-prefix recurse-submodules-default] },
        "pull" => { short: "sXjo", long: %w[depth deepen shallow-since shallow-exclude upload-pack jobs negotiation-tip server-option refmap filter strategy strategy-option cleanup] },
        "clone" => { short: "obucj", long: %w[origin branch upload-pack reference reference-if-able separate-git-dir depth shallow-since shallow-exclude config template jobs filter server-option bundle-uri revision ref-format] },
        "ls-remote" => { short: "o", long: %w[upload-pack exec sort server-option] }
      }.freeze

      module_function

      def docker(args, ctx)
        scan = Args.scan(args, short: DOCKER_SHORT, long: DOCKER_LONG, interleaved: false)
        host_word = scan.values("-H", "--host").last || ctx.env["DOCKER_HOST"]
        context = (scan.values("-c", "--context").last || ctx.env["DOCKER_CONTEXT"])&.literal
        found = []
        daemon_host = context ? nil : Record::FS.host
        if host_word
          text = host_word.literal
          daemon = daemon_place(text)
          found << daemon if daemon
          daemon_host = daemon ? daemon["host"] : (local_daemon?(text) ? Record::FS.host : nil)
        end
        command = scan.operands + scan.rest
        command = command[1..] if command.first&.text == "container"
        container = docker_target(command, daemon_host, context)
        found << container if container
        found.map { |place| [place, "docker", "argument"] }
      end

      def daemon_place(text)
        return nil unless text

        url = Targets.parse_url(text)
        return nil unless url && %w[tcp ssh http https].include?(url[:scheme])

        Targets.host_place(url[:host], port: url[:port])
      end

      def local_daemon?(text)
        text.to_s.match?(%r{\A(?:unix|npipe|fd)://})
      end

      def docker_target(command, daemon_host, context)
        case command.first&.text
        when "exec"
          scan = Args.scan(command[1..], short: DOCKER_EXEC_SHORT, long: DOCKER_EXEC_LONG, interleaved: false)
          name = scan.operands.first&.literal
          name && Targets.container_place(daemon_host: daemon_host, container: name, context: context)
        when "run"
          scan = Args.scan(command[1..], short: DOCKER_RUN_SHORT, long: DOCKER_RUN_LONG, interleaved: false)
          image = scan.operands.first&.literal
          name = scan.values("--name").last&.literal
          image && Targets.container_place(daemon_host: daemon_host, container: name, image: image, context: context)
        end
      end

      def kubectl(args, _ctx)
        scan = Args.scan(args, short: KUBECTL_SHORT, long: KUBECTL_LONG)
        words = scan.operands.map(&:text)
        verb = words.first
        return [] if verb.nil? || KUBECTL_LOCAL.include?(verb)
        return [] if verb == "version" && scan.flag?("--client")

        server = scan.values("-s", "--server").last&.literal
        server_host = server && (Targets.parse_url(server)&.dig(:host) || server)
        place = Targets.cluster_place(
          server_host: server_host && Targets.clean_host(server_host),
          context: scan.values("--context").last&.literal,
          namespace: scan.values("-n", "--namespace").last&.literal,
          target: kubectl_target(verb, scan)
        )
        [[place, "kubectl", "argument"]]
      end

      def kubectl_target(verb, scan)
        return nil unless KUBECTL_TARGETED.include?(verb)

        pod = scan.values("-p").last if verb == "exec"
        (pod || scan.operands[1])&.literal
      end

      def git(args, ctx)
        scan = Args.scan(args, short: GIT_SHORT, long: GIT_LONG, interleaved: false)
        cwd = scan.values("-C").reduce(ctx.cwd) { |dir, value| change_dir(dir, value.literal) }
        command = scan.operands + scan.rest
        name = command.first&.text
        return remote_add(command[1..], cwd) if name == "remote"

        spec = GIT_COMMANDS[name]
        return [] unless spec

        sub = Args.scan(command[1..], short: spec[:short], long: spec[:long])
        repositories(name, sub, cwd, ctx.lookup).uniq
      end

      def repositories(name, sub, cwd, lookup)
        explicit = sub.values("--repo").filter_map(&:literal)
        first = sub.operands.first
        if name != "clone" && (sub.flag?("--all") || (name == "fetch" && sub.flag?("--multiple")))
          named = sub.flag?("--all") ? [:all] : sub.operands.filter_map(&:literal)
          return named.flat_map { |remote| repository_targets(remote, cwd, lookup) }
        end
        return [] if first&.dynamic
        return explicit.flat_map { |text| repository_targets(text, cwd, lookup) } if first.nil? && !explicit.empty?
        return repository_targets(nil, cwd, lookup) if first.nil? && name != "clone"
        return [] if first.nil?

        name == "clone" ? url_targets(first.text, cwd, "url") : repository_targets(first.text, cwd, lookup)
      end

      def remote_add(command, cwd)
        return [] unless command.first&.text == "add"

        sub = Args.scan(command[1..], short: "tm", long: %w[mirror])
        url = sub.operands[1]&.literal
        url ? url_targets(url, cwd, "url") : []
      end

      def repository_targets(text, cwd, lookup)
        return url_targets(text, cwd, "url") if text.is_a?(String) && url_like?(text)
        return [] unless lookup && cwd

        Array(lookup.call(text, cwd)).compact.flat_map do |url|
          url_like?(url) ? url_targets(url, cwd, "git_remote") : []
        end
      end

      def url_like?(text)
        text.include?("://") || !Targets.parse_scp(text).nil? || text.start_with?("/", "./", "../") || text == "." || text == ".."
      end

      def url_targets(text, cwd, evidence)
        place = repository_place(text, cwd)
        place ? [[place, "git", evidence]] : []
      end

      def repository_place(text, cwd)
        if (url = Targets.parse_url(text))
          return Targets.repository_place(nil, url[:path], local: true) if url[:scheme] == "file" && url[:path].start_with?("/")
          return nil if url[:scheme] == "file"

          return Targets.repository_place(url[:host], url[:path])
        end
        if (scp = Targets.parse_scp(text))
          return Targets.repository_place(scp[:host], scp[:path])
        end
        return nil if text.start_with?("~")

        absolute = text.start_with?("/") ? text : (cwd && File.expand_path(text, cwd))
        absolute && Targets.repository_place(nil, File.expand_path(absolute), local: true)
      end

      def change_dir(dir, value)
        return nil if value.nil? || value.start_with?("~")
        return File.expand_path(value) if value.start_with?("/")

        dir && File.expand_path(value, dir)
      end
    end
  end
end
