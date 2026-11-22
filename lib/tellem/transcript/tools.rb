# frozen_string_literal: true

require "json"

module Tellem
  module Transcript
    module Tools
      LANGUAGES = {
        ".rb" => "ruby", ".py" => "python", ".js" => "javascript", ".ts" => "typescript", ".sh" => "bash",
        ".yml" => "yaml", ".yaml" => "yaml", ".json" => "json", ".md" => "markdown", ".sql" => "sql",
        ".go" => "go", ".rs" => "rust", ".toml" => "toml", ".html" => "html", ".css" => "css", ".lua" => "lua"
      }.freeze

      module_function

      def block(tool, link: nil)
        name = tool["name"].to_s
        parts = ["<tool-use data-tool-type=\"#{attr(tool['type'])}\" data-tool-name=\"#{attr(name)}\"><details>",
                 "<summary>Tool use: **#{name}**</summary>"]
        input = input_section(tool)
        parts << input unless input.empty?
        parts << "Subagent transcript: [#{link}](#{link})" if link
        result = result_section(tool)
        lines = parts.join("\n")
        lines = "#{lines.chomp}\n\n#{result}" if result
        "#{lines}\n</details></tool-use>"
      end

      def attr(value)
        value.to_s.gsub("&", "&amp;").gsub('"', "&quot;").gsub("<", "&lt;").gsub(">", "&gt;")
      end

      def input_section(tool)
        input = tool["input"]
        return omitted(input) if omitted?(input)

        case tool["type"]
        when "shell" then shell(input)
        when "read" then read(input, tool["cwd"])
        when "write" then write(tool["name"], input)
        when "agent" then agent(tool["name"], input)
        else generic(tool, input)
        end
      end

      def omitted?(value)
        value.is_a?(Hash) && value.keys == ["content_omitted"]
      end

      def omitted(value)
        "\ncontent_omitted: #{value['content_omitted']} bytes"
      end

      def shell(input)
        return "\n#{fenced(input, 'javascript')}" if input.is_a?(String)
        return generic_list(input) unless input.is_a?(Hash)

        command = input["command"] || input["cmd"]
        command = command.join(" ") if command.is_a?(Array)
        return generic_list(input) unless command.is_a?(String)

        description = input["description"].is_a?(String) && !input["description"].empty? ? input["description"] : nil
        rendered = inline_or_fenced(command, "bash")
        description ? "#{description}\n\n#{rendered}" : "\n#{rendered}"
      end

      def read(input, cwd)
        return generic_list(input) unless input.is_a?(Hash)

        path = input["file_path"] || input["path"] || input["notebook_path"]
        return generic_list(input) unless path.is_a?(String)

        prefix = cwd.is_a?(String) ? "#{cwd.chomp('/')}/" : nil
        shown = prefix && path.start_with?(prefix) ? "./#{path.delete_prefix(prefix)}" : path
        " `#{shown}`"
      end

      def write(name, input)
        return generic_list(input) unless input.is_a?(Hash)
        return "" if %w[Edit MultiEdit NotebookEdit].include?(name)

        content = input["content"]
        return generic_list(input) unless content.is_a?(String)

        "\n#{fenced(content, language(input['file_path']))}"
      end

      def agent(name, input)
        return generic(nil, input) unless %w[Task Agent].include?(name) && input.is_a?(Hash)

        input["description"].is_a?(String) ? input["description"] : ""
      end

      def generic(tool, input)
        question = tool && tool["name"] == "AskUserQuestion" ? ask(tool, input) : nil
        question || generic_list(input)
      end

      def generic_list(input)
        return "" if input.nil? || (input.respond_to?(:empty?) && input.empty?)
        return "\n**Input:**\n\n#{fenced(input.to_s, 'text')}\n" unless input.is_a?(Hash)

        rows = input.keys.sort.map { |key| "- #{key}: #{value(input[key])}" }
        "\n**Input:**\n\n#{rows.join("\n")}\n"
      end

      def value(item)
        text = item.is_a?(String) ? item : JSON.generate(item)
        ticks = "`" * ((text.scan(/`+/).map(&:length).max || 0) + 1)
        ticks == "`" ? "`#{text}`" : "#{ticks} #{text} #{ticks}"
      end

      def ask(tool, input)
        questions = input.is_a?(Hash) ? input["questions"] : nil
        return nil unless questions.is_a?(Array) && questions.all?(Hash)

        answers = tool["answers"].is_a?(Hash) ? tool["answers"] : {}
        sections = questions.map do |entry|
          options = Array(entry["options"]).select { |option| option.is_a?(Hash) }.map do |option|
            "- **#{option['label']}** - #{option['description']}"
          end
          text = "**#{entry['question']}**\n\nOptions:\n#{options.join("\n")}\n"
          answer = answers[entry["question"]]
          answer ? "#{text}\n\n**Answer:** #{answer}" : text
        end
        sections.join("\n\n")
      end

      def result_section(tool)
        return nil if tool["name"] == "AskUserQuestion" && tool["answers"].is_a?(Hash)

        result = tool["result"]
        return nil if result.nil?

        body = omitted?(result) ? "[content_omitted: #{result['content_omitted']} bytes]" : result.to_s
        fenced(body, "text")
      end

      def inline_or_fenced(text, lang)
        return "`#{text}`" unless text.include?("\n") || text.include?("`")

        fenced(text, lang)
      end

      def fenced(text, lang)
        fence = "`" * [3, (text.scan(/`{3,}/).map(&:length).max || 0) + 1].max
        "#{fence}#{lang}\n#{text.chomp}\n#{fence}"
      end

      def language(path)
        LANGUAGES.fetch(File.extname(path.to_s).downcase, "text")
      end
    end
  end
end
