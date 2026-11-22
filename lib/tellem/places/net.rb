# frozen_string_literal: true

require_relative "args"
require_relative "shell"
require_relative "targets"

module Tellem
  module Places
    module Net
      SSH_SHORT = "BbcDEeFIiJLlmOopQRSWw"
      SCP_SHORT = "cDFiJlOoPSX"
      RSYNC_SHORT = "efTBM"
      RSYNC_LONG = %w[
        rsh rsync-path filter exclude include exclude-from include-from files-from temp-dir port block-size log-file
        log-file-format password-file link-dest compare-dest copy-dest backup-dir suffix chmod chown timeout contimeout
        bwlimit remote-option partial-dir max-size min-size max-delete out-format info debug iconv usermap groupmap
        sockopts skip-compress outbuf write-batch only-write-batch read-batch protocol checksum-choice compress-choice
        compress-level checksum-seed address modify-window stop-after stop-at max-alloc
      ].freeze
      CURL_SHORT = "AbcCdDeEFHKmoPQrTuUwxXYyz"
      CURL_LONG = %w[
        url proxy preproxy header proxy-header data data-raw data-binary data-urlencode data-ascii json user proxy-user
        oauth2-bearer output user-agent referer cookie cookie-jar form form-string upload-file write-out config max-time
        connect-timeout request range resolve connect-to cacert capath cert key pass retry retry-delay retry-max-time
        limit-rate interface dns-servers dns-interface dns-ipv4-addr dns-ipv6-addr output-dir create-file-mode dump-header
        trace trace-ascii stderr expect100-timeout keepalive-time max-filesize max-redirs noproxy socks4 socks4a socks5
        socks5-hostname socks5-gssapi-service unix-socket abstract-unix-socket aws-sigv4 variable url-query
        happy-eyeballs-timeout-ms hostpubmd5 hostpubsha256 krb local-port login-options mail-from mail-rcpt mail-auth
        netrc-file proto proto-redir proto-default proxy-cacert proxy-capath proxy-cert proxy-cert-type proxy-key
        proxy-key-type proxy-pass proxy-ciphers proxy-tls13-ciphers proxy-tlsuser proxy-tlspassword proxy-service-name
        sasl-authzid service-name tls-max tlsuser tlspassword ciphers tls13-ciphers curves cert-type key-type engine
        delegation ftp-port ftp-account ftp-alternative-to-user ftp-method ftp-ssl-ccc-mode quote time-cond speed-limit
        speed-time telnet-option tftp-blksize continue-at crlfile pinnedpubkey random-file egd-file request-target
        ip-tos vlan-priority etag-compare etag-save ech parallel-max rate retry-all-errors-delay
      ].freeze
      CURL_TARGETS = %w[--url --proxy -x --preproxy --socks4 --socks4a --socks5 --socks5-hostname].freeze
      WGET_SHORT = "aBDeIilOoPQRtTUwXAl"
      WGET_LONG = %w[
        output-document output-file append-output input-file base execute tries timeout wait quota level accept reject
        domains exclude-domains header user password http-user http-password proxy-user proxy-password ftp-user
        ftp-password post-data post-file body-data body-file method user-agent referer load-cookies save-cookies
        directory-prefix ca-certificate ca-directory certificate certificate-type private-key private-key-type
        bind-address limit-rate dns-timeout connect-timeout read-timeout waitretry cut-dirs default-page
        restrict-file-names include-directories exclude-directories config use-askpass ciphers secure-protocol
        progress local-encoding remote-encoding accept-regex reject-regex regex-type warc-file warc-header
        warc-max-size warc-dedup warc-tempdir report-speed retry-on-http-error backups rejected-log crl-file
        pinnedpubkey random-file egd-file hsts-file e-robots
      ].freeze

      module_function

      def ssh(args, _ctx)
        scan = Args.scan(args, short: SSH_SHORT, stop_after: 1)
        port = scan.values("-p").last&.literal
        found = []
        destination = scan.operands.first&.literal
        found << ssh_destination(destination, port) if destination
        found.concat(jump_hosts(scan.values("-J")))
        found.compact.map { |place| [place, "ssh", "argument"] }
      end

      def ssh_destination(text, port)
        if (url = Targets.parse_url(text))
          return nil unless url[:scheme] == "ssh"

          return Targets.host_place(url[:host], port: url[:port] || port)
        end
        host = text.include?("@") ? text[(text.rindex("@") + 1)..] : text
        Targets.host_place(host, port: port)
      end

      def jump_hosts(values)
        values.filter_map(&:literal).flat_map { |list| list.split(",") }.filter_map do |hop|
          next nil if hop.empty? || hop == "none"

          if (url = Targets.parse_url(hop))
            Targets.host_place(url[:host], port: url[:port])
          else
            host = hop.include?("@") ? hop[(hop.rindex("@") + 1)..] : hop
            name, port = Targets.split_hostport(host)
            Targets.host_place(name, port: port)
          end
        end
      end

      def scp(args, _ctx)
        scan = Args.scan(args, short: SCP_SHORT)
        port = scan.values("-P").last&.literal
        found = jump_hosts(scan.values("-J"))
        scan.operands.filter_map(&:literal).each { |operand| found << copy_target(operand, port) }
        found.compact.map { |place| [place, "scp", "argument"] }
      end

      def copy_target(operand, port, daemon_port: nil)
        if (url = Targets.parse_url(operand))
          return nil unless %w[scp sftp rsync ssh].include?(url[:scheme])

          return Targets.host_place(url[:host], port: url[:port] || (url[:scheme] == "rsync" ? daemon_port : port))
        end
        if (daemon = operand.match(/\A(?:[^\/:]*@)?(?<host>[^\/:\[\]@]+)::/))
          return Targets.host_place(daemon[:host], port: daemon_port)
        end
        scp = Targets.parse_scp(operand)
        scp && Targets.host_place(scp[:host], port: port)
      end

      def rsync(args, _ctx)
        scan = Args.scan(args, short: RSYNC_SHORT, long: RSYNC_LONG)
        shell = scan.values("-e", "--rsh").last&.literal
        port = nil
        found = []
        if shell
          words = Shell.segments(shell).first&.words || []
          if Args.program_name(words.first) == "ssh"
            inner = Args.scan(words[1..], short: SSH_SHORT)
            port = inner.values("-p").last&.literal
            found.concat(jump_hosts(inner.values("-J")))
          end
        end
        daemon_port = scan.values("--port").last&.literal
        scan.operands.filter_map(&:literal).each { |operand| found << copy_target(operand, port, daemon_port: daemon_port) }
        found.compact.map { |place| [place, "rsync", "argument"] }
      end

      def curl(args, _ctx)
        scan = Args.scan(args, short: CURL_SHORT, long: CURL_LONG)
        texts = scan.options.select { |option| CURL_TARGETS.include?(option.name) }.filter_map { |option| option.value&.literal }
        texts.concat(scan.operands.filter_map(&:literal))
        texts.filter_map { |text| url_target(text) }.map { |place| [place, "curl", "url"] }
      end

      def wget(args, _ctx)
        scan = Args.scan(args, short: WGET_SHORT, long: WGET_LONG)
        scan.operands.filter_map(&:literal).filter_map { |text| url_target(text) }.map { |place| [place, "wget", "url"] }
      end

      def url_target(text)
        if (url = Targets.parse_url(text))
          return nil if %w[file unix].include?(url[:scheme])

          return Targets.domain_place(url[:host], port: url[:port])
        end
        return nil if text.start_with?("/", ".", "~", "-", "@")

        hostport = text.split(%r{[/?#]}, 2).first.to_s
        hostport = hostport[(hostport.rindex("@") + 1)..] if hostport.include?("@")
        host, port = Targets.split_hostport(hostport)
        return nil unless host && (host.include?(".") || host.include?(":") || host.casecmp?("localhost"))

        Targets.domain_place(host, port: port)
      end
    end
  end
end
