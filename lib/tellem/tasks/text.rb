# frozen_string_literal: true

module Tellem
  module Tasks
    module Text
      STRIP_TAGS = %r{</?[A-Za-z_][\p{L}\p{N}_-]*(?:[[:space:]\x1c-\x1f][^>]*)?>}
      TOKEN = %r{[A-Za-z0-9_][A-Za-z0-9_.\-/]*}
      SPACE = /[[:space:]\x1c-\x1f]+/
      LEAD = /\A[[:space:]\x1c-\x1f]+/
      TRAIL = /[[:space:]\x1c-\x1f]+\z/
      EDGE = /\A[^\p{L}\p{N}_]+|[^\p{L}\p{N}_]+\z/
      PROMPT_CHARS = 20_000
      HEAD_CHARS = 120
      NAME_CHARS = 60
      STOPWORDS = %w[
        a about above after again against all also am an and any are aren't as at be because been before being below between both but by
        can cannot could couldn't did didn't do does doesn't doing don't down during each few for from further had hadn't has hasn't have
        haven't having he her here hers herself him himself his how i i'm i'd i'll i've if in into is isn't it it's its itself let lets
        me more most my myself no nor not of off on once only or other ought our ours ourselves out over own same shall she should
        shouldn't so some such than that the their theirs them themselves then there these they this those through to too under until
        up very was wasn't we were weren't what when where which while who whom why will with won't would wouldn't you your yours
        yourself yourselves please want need like just now sure okay yes thing things way get got use using see look check make
        makes made wants really maybe still even much many well back going gonna able tell show give take put say said know
        think thought try trying works work working yeah yep ok ones one two three first next last new old good great nice right
        actually basically already always never ever else every anything something everything nothing anyone someone everyone
      ].to_h { |word| [word, true] }.freeze

      module_function

      def str(value)
        value.nil? || value == false ? "" : value.to_s
      end

      def lstrip(text)
        text.sub(LEAD, "")
      end

      def rstrip(text)
        text.sub(TRAIL, "")
      end

      def words(text)
        text.split(SPACE).reject(&:empty?)
      end

      def strip_tags(text)
        str(text).gsub(STRIP_TAGS, " ")
      end

      def collapse(text)
        words(str(text)).join(" ")
      end

      def head(text, limit)
        collapse(text)[0, limit]
      end

      def tokens(text)
        seen = {}
        strip_tags(str(text)[0, PROMPT_CHARS]).scan(TOKEN) do |match|
          word = match.sub(%r{[.\-/]+\z}, "").downcase
          candidates = [word]
          if word.include?("/")
            base = word.split("/", -1).last
            candidates << base
            candidates << base.sub(/\.[^.]*\z/, "") if base.include?(".")
          end
          candidates.each do |item|
            seen[item] = true if item.length >= 3 && !item.match?(/\A\d+\z/) && !STOPWORDS.key?(item) && !seen.key?(item)
          end
        end
        seen.keys
      end

      def containment(prompt_tokens, fingerprint)
        prompt_set = prompt_tokens.uniq
        return nil if prompt_set.empty?

        known = fingerprint.to_h { |word| [word, true] }
        prompt_set.count { |word| known.key?(word) }.to_f / prompt_set.length
      end

      def question?(text, cues)
        value = str(text)
        tail = value.length > 400 ? value[-400..] : value
        tail = rstrip(tail).sub(/[ *_`)"']+\z/, "")
        tail.end_with?("?") || cues.any? { |cue| tail.downcase.include?(cue) }
      end

      def split_path(path)
        index = path.rindex("/")
        return ["", path] unless index

        head = path[0..index]
        head = head.sub(%r{/+\z}, "") unless head.match?(%r{\A/+\z})
        [head, path[(index + 1)..]]
      end

      def basename(path)
        split_path(path).last
      end

      def dirname(path)
        split_path(path).first
      end

      def stem(base)
        base.include?(".") ? base.sub(/\.[^.]*\z/, "") : base
      end

      def deep_copy(value)
        case value
        when Hash then value.each_with_object({}) { |(key, item), out| out[key] = deep_copy(item) }
        when Array then value.map { |item| deep_copy(item) }
        when String then value.dup
        else value
        end
      end

      def stringify(value)
        case value
        when Hash then value.each_with_object({}) { |(key, item), out| out[key.to_s] = stringify(item) }
        when Array then value.map { |item| stringify(item) }
        else value
        end
      end
    end
  end
end
