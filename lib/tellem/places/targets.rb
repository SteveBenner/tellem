# frozen_string_literal: true

require_relative "../ids"
require_relative "../redact"
require_relative "../record/fs"
require_relative "../record/kinds"
require_relative "../record/formats"

module Tellem
  module Places
    module Targets
      LABEL = "[a-z0-9_](?:[a-z0-9_-]{0,62})?"
      HOSTNAME = /\A#{LABEL}(?:\.#{LABEL})*\z/o
      IPV4 = /\A\d{1,3}(?:\.\d{1,3}){3}\z/
      IPV6 = /\A[0-9a-f]*:[0-9a-f:.]*\z/
      SCHEME_URL = %r{\A(?<scheme>[A-Za-z][A-Za-z0-9+.-]*)://(?<rest>.*)\z}m
      SCP_LIKE = /\A(?:(?<user>[^\/@]*)@)?(?<host>\[[^\]\/]+\]|[^\/:\[\]@]+):(?<path>.*)\z/m
      TEXT_BYTES = 1024
      PLACE_ENUMS = Record::Kinds.fetch("place")[:enums]

      module_function

      def clean_host(raw)
        return nil unless raw.is_a?(String)

        host = raw.strip.downcase
        host = host[1..-2] if host.start_with?("[") && host.end_with?("]")
        host = host.chomp(".")
        return nil if host.empty? || host.bytesize > 253
        return nil unless HOSTNAME.match?(host) || IPV4.match?(host) || IPV6.match?(host)
        return nil unless Redact.text(host) == host

        host
      end

      def clean_port(raw)
        return nil if raw.nil? || raw.to_s.empty?
        return nil unless raw.to_s.match?(/\A\d{1,5}\z/)

        port = raw.to_s.to_i
        port.between?(1, 65_535) ? port : nil
      end

      def safe_text(value)
        return nil unless value.is_a?(String) && !value.empty?

        text = Redact.text(value.scrub(""))
        text.bytesize > TEXT_BYTES ? text.byteslice(0, TEXT_BYTES).scrub("") : text
      end

      def parse_url(text)
        match = SCHEME_URL.match(text.to_s)
        return nil unless match

        rest = match[:rest]
        authority, path = split_authority(rest)
        hostport = authority.include?("@") ? authority[(authority.rindex("@") + 1)..] : authority
        host, port = split_hostport(hostport)
        { scheme: match[:scheme].downcase, host: host, port: port, path: path.sub(/[?#].*\z/m, "") }
      end

      def split_authority(rest)
        cut = rest.index(%r{[/?#]})
        cut ? [rest[0, cut], rest[cut..]] : [rest, ""]
      end

      def split_hostport(text)
        if text.start_with?("[")
          close = text.index("]")
          return [nil, nil] unless close

          [text[0..close], text[(close + 1)..].to_s.delete_prefix(":")]
        elsif text.count(":") == 1
          text.split(":", 2)
        else
          [text, nil]
        end
      end

      def parse_scp(text)
        match = SCP_LIKE.match(text.to_s)
        return nil unless match
        return nil if match[:host].length == 1 && match[:user].nil?

        { host: match[:host], path: match[:path] }
      end

      def sanitize_url(text)
        return nil unless text.is_a?(String) && !text.empty?

        if (url = parse_url(text))
          host = clean_host(url[:host])
          port = clean_port(url[:port])
          authority = host ? (host.include?(":") ? "[#{host}]" : host) : ""
          authority += ":#{port}" if port
          safe_text("#{url[:scheme]}://#{authority}#{url[:path]}")
        elsif (scp = parse_scp(text))
          host = clean_host(scp[:host])
          host ? safe_text("#{host}:#{scp[:path].sub(/[?#].*\z/m, '')}") : nil
        else
          safe_text(text.sub(/[?#].*\z/m, ""))
        end
      end

      def place(kind, host:, extras: {}, resolved: "full")
        attributes = extras.compact
        identity = { "kind" => kind, "host" => host }.merge(attributes)
        body = {
          "place_id" => Ids.place_id(identity),
          "kind" => kind,
          "host" => host,
          "real_path" => nil,
          "resolved" => resolved,
          "repository_id" => nil,
          "attributes" => attributes
        }
        Record::Formats.check_enums(body, PLACE_ENUMS)
        body
      end

      def host_place(raw_host, port: nil)
        host = clean_host(raw_host)
        host && place("host", host: host, extras: { "port" => clean_port(port) })
      end

      def domain_place(raw_host, port: nil)
        host = clean_host(raw_host)
        host && place("domain", host: host, extras: { "port" => clean_port(port) })
      end

      def container_place(daemon_host:, container: nil, image: nil, context: nil)
        return nil if container.nil? && image.nil?

        extras = { "container" => safe_text(container), "image" => safe_text(image), "context" => safe_text(context) }
        place("container", host: daemon_host, extras: extras, resolved: daemon_host ? "full" : "partial")
      end

      def cluster_place(server_host: nil, context: nil, namespace: nil, target: nil)
        extras = { "context" => safe_text(context), "namespace" => safe_text(namespace), "target" => safe_text(target) }
        known = server_host || context
        place("cluster", host: server_host, extras: extras, resolved: known ? "full" : "partial")
      end

      def repository_place(raw_host, path, local: false)
        host = local ? Record::FS.host : clean_host(raw_host)
        clean = repository_path(path, local: local)
        return nil unless host && clean

        place("remote_repository", host: host, extras: { "path" => clean })
      end

      def repository_path(path, local:)
        text = path.to_s.sub(/[?#].*\z/m, "")
        text = text.chomp("/") while text.length > 1 && text.end_with?("/")
        text = text.delete_suffix(".git")
        text = text.sub(%r{\A/+}, "") unless local
        safe_text(text)
      end
    end
  end
end
