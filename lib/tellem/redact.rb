# frozen_string_literal: true

module Tellem
  module Redact
    SECRET_NAME = /
      (?=.)
      (?!.*(?:\A|(?<=[_.-])|(?<=[a-z])(?=[A-Z]))
        (?i:name|id|file|path|dir|url|uri|type|kind|ref|env|count|size|length|ttl|expiry|expires|header|field|prefix)\z)
      .*?
      (?:\A|(?<=[_.-])|(?<=[a-z])(?=[A-Z]))
      (?i:
        password|passwd|secret|token|credentials?|apikey
        |(?:api|private|access|auth|signing|encryption|master)(?:[_.-]|(?<=[a-z])(?=[A-Z]))?key
        |client(?:[_.-]|(?<=[a-z])(?=[A-Z]))?secret
      )
      (?=\z|[_.-]|(?<=[a-z])[A-Z])
      .*
    /x
    SECRET_NAME_EXACT = /\A(?:#{SECRET_NAME})\z/
    NAME = /[A-Za-z0-9_.-]+/
    QUOTED = /"(?:\\.|[^"\\\n])*"|'[^'\n]*'|`[^`\n]*`/
    QUOTES = ['"', "'", "`"].freeze
    TRAILING = /["'`),;\]]\z/
    TRAILING_RUN = /["'`),;\]}:.]+\z/
    MARKER = /\A\[REDACTED:[a-z_]+\]\z/
    MARKER_VALUE = /\A\[REDACTED:[a-z_]+\]["'`),;\]}:.]*\z/
    BOUNDARY = /(?:\A|(?<=[\s?&;,(\[{"'`]))/
    SCHEMES = %w[bearer basic token apikey].freeze
    CREDENTIAL_SHAPE = %r{\A[A-Za-z0-9+/_=-]{16,}\z}
    COMPONENT_SPLIT = /[_.-]|(?<=[a-z])(?=[A-Z])/
    KEYWORDS = %w[true false null nil none yes no].freeze
    CODE_START = ["/", "[", "{", "(", "<", ">", "|", "&", "*", "%"].freeze
    CODE_IDENTIFIER = /\A[A-Za-z_][A-Za-z0-9_]*(?:\.|\[|\(|::)/
    MIN_BARE = 4

    TOKEN_RULES = [
      [:private_key, /-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----.*?(?:-----END [A-Z0-9 ]*PRIVATE KEY-----|\z)/m],
      [:anthropic_key, /\bsk-ant-[A-Za-z0-9_-]{8,}/],
      [:openai_key, /\bsk-(?:proj-)?[A-Za-z0-9_-]{20,}/],
      [:github_token, /\b(?:gh[posu]_[A-Za-z0-9]{20,255}|github_pat_[A-Za-z0-9_]{20,255})/],
      [:gitlab_token, /\bglpat-[A-Za-z0-9_-]{20,}/],
      [:slack_token, /\bxox[a-z]-[A-Za-z0-9-]{10,}/],
      [:aws_access_key, /\b(?:AKIA|ASIA)[0-9A-Z]{16}\b/],
      [:jwt, /\beyJ[A-Za-z0-9_-]{4,}\.eyJ[A-Za-z0-9_-]{4,}\.[A-Za-z0-9_-]{8,}/]
    ].freeze

    USERINFO = %r{(?<pre>[A-Za-z][A-Za-z0-9+.-]*://)(?!\[REDACTED:[a-z_]+\]@)[^/\s@?#"']+(?=@)}
    AUTH_HEADER = /
      (?<pre>\bAuthorization["']?[ \t]*[:=][ \t]*["'`]?)
      (?:(?<scheme>[A-Za-z]+)[ \t]+)?
      (?<value>[^\s]+)
    /xi
    CREDENTIAL = /(?<pre>\b(?:Bearer|Basic)[ \t]+)(?!\[REDACTED:)[A-Za-z0-9._~+\/-]{16,}=*/
    ASSIGNMENT = /
      #{BOUNDARY}
      (?:
        (?<pre>(?<q>["']?)(?<name>#{NAME})\k<q>[ \t]*(?:=(?![=~>])|:(?!:))[ \t]*)
        |
        (?<pre>--(?<name>#{NAME})(?:=|[ \t]+))
      )
      (?<value>#{QUOTED}|\S+)
    /x

    module_function

    def text(input)
      return input unless input.is_a?(String)

      out = input.dup
      out = out.encode("UTF-8", invalid: :replace, undef: :replace) unless out.encoding == Encoding::UTF_8 && out.valid_encoding?
      document = json_document(out)
      return document if document

      rules(out)
    end

    def rules(out)
      out = out.gsub(USERINFO) { [Regexp.last_match[:pre], marker(:userinfo)].join }
      out = out.gsub(AUTH_HEADER) { authorization(Regexp.last_match) }
      out = out.gsub(CREDENTIAL) { [Regexp.last_match[:pre], marker(:authorization)].join }
      TOKEN_RULES.each { |kind, pattern| out = out.gsub(pattern) { marker(kind) } }
      assignments(out)
    end

    def json_document(input)
      body = input.strip
      return nil unless (body.start_with?("{") && body.end_with?("}")) || (body.start_with?("[") && body.end_with?("]"))

      require "json"
      parsed = begin
        JSON.parse(body)
      rescue JSON::ParserError, EncodingError
        return nil
      end
      redacted = structure(parsed)
      return input if redacted == parsed

      lead = input[/\A\s*/]
      tail = input[/\s*\z/]
      serialized = body.include?("\n") ? JSON.pretty_generate(redacted) : JSON.generate(redacted)
      "#{lead}#{serialized}#{tail}"
    end

    def structure(node)
      case node
      when Hash
        node.each_with_object({}) do |(key, value), out|
          out[rules(key)] = keyed(key, value)
        end
      when Array then node.map { |value| structure(value) }
      when String then rules(node)
      else node
      end
    end

    def keyed(key, value)
      return structure(value) if value.is_a?(Hash) || value.is_a?(Array)
      return scalar_marker(value) if secret_name?(key)
      return value unless value.is_a?(String)

      prefix = "#{key}: "
      joined = rules("#{prefix}#{value}")
      joined.start_with?(prefix) ? joined[prefix.length..] : rules(value)
    end

    def scalar_marker(value)
      return value if value.nil? || value == true || value == false || value == ""
      return value if value.is_a?(String) && MARKER.match?(value)

      marker(:assignment)
    end

    def assignments(text)
      out = +""
      pos = 0
      while (match = ASSIGNMENT.match(text, pos))
        if secret_name?(match[:name]) && !prose_between_spans?(text, match)
          out << text[pos...match.begin(0)] << replace(match, :assignment)
          pos = match.end(0)
        else
          stop = match.end(:name)
          out << text[pos...stop]
          pos = stop
        end
      end
      out << text[pos..]
    end

    def prose_between_spans?(text, match)
      value = match[:value]
      return false unless value.length > 2 && value.start_with?("`") && value.end_with?("`")

      start = match.begin(:name)
      return false unless start.positive? && text[start - 1] == "`" && !match[:pre].match?(/[ \t]\z/)

      following = text[match.end(:value)]
      value[1].match?(/\s/) && !following.nil? && following.match?(/[^\s`]/)
    end

    def authorization(match)
      scheme = match[:scheme]
      known = scheme && SCHEMES.include?(scheme.downcase)
      if scheme && !known
        return match[0] unless credential_shaped?(scheme)

        return "#{match[:pre]}#{marker(:authorization)} #{match[:value]}"
      end
      value = match[:value]
      trailing = value.match?(TRAILING) ? value[-1] : ""
      token = trailing.empty? ? value : value[0...-1]
      return match[0] if token.start_with?("[REDACTED:")
      return match[0] unless known || credential_shaped?(token)

      "#{match[:pre]}#{scheme ? "#{scheme} " : ''}#{marker(:authorization)}#{trailing}"
    end

    def credential_shaped?(token)
      CREDENTIAL_SHAPE.match?(token)
    end

    def url(input)
      return input unless input.is_a?(String)

      base, fragment = input.split("#", 2)
      base, query = base.split("?", 2)
      redacted = text(base)
      redacted += "?[REDACTED:query]" if query && !query.empty?
      redacted += "#[REDACTED:fragment]" if fragment && !fragment.empty?
      redacted
    end

    def secret_name?(name)
      SECRET_NAME_EXACT.match?(name.to_s)
    end

    def replace(match, kind)
      value = match[:value]
      return match[0] if marker_value?(value)
      if value.start_with?(*QUOTES) && QUOTED.match?(value) && value.end_with?(value[0]) && value.length >= 2
        return "#{match[:pre]}#{value[0]}#{marker(kind)}#{value[0]}"
      end

      trailing = value[TRAILING_RUN] || ""
      bare = value[0, value.length - trailing.length]
      return match[0] unless secret_value?(bare.strip)
      return match[0] if match.names.include?("name") && self_named?(bare.strip, match[:name])

      "#{match[:pre]}#{marker(kind)}#{trailing}"
    end

    def marker_value?(value)
      unquoted = QUOTES.include?(value[0]) && value.length >= 2 && value.end_with?(value[0]) ? value[1...-1] : value
      MARKER_VALUE.match?(unquoted)
    end

    def secret_value?(value)
      return false if value.length < MIN_BARE
      return false if value.start_with?("$") || value.start_with?("ENV[")
      return false if CODE_START.include?(value[0])
      return false if CODE_IDENTIFIER.match?(value)

      !KEYWORDS.include?(value.downcase)
    end

    def self_named?(value, name)
      lowered = value.downcase
      [name, *name.to_s.split(COMPONENT_SPLIT)].any? { |part| !part.empty? && part.downcase == lowered }
    end

    def marker(kind)
      "[REDACTED:#{kind}]"
    end
  end
end
