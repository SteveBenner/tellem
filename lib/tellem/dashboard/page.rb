# frozen_string_literal: true

require "digest"
require "json"

module Tellem
  module Dashboard
    module Page
      WEB = File.expand_path("web", __dir__)
      VENDOR = File.join(WEB, "vendor", "rui")
      STYLED = %w[
        composite.data.table
        composite.card.stat-row
        primitive.display.badge
        composite.navigation.tabs
        composite.navigation.tree-explorer
        primitive.input.select
        composite.chart.time-series
        composite.data.ranked-list
        pattern.scale.ui-zoom
        composite.feedback.loading-skeleton
      ].freeze
      SCRIPTED = (STYLED - %w[composite.feedback.loading-skeleton]).freeze
      ZOOM = "pattern.scale.ui-zoom"
      APP = %w[format data shell sessions timeline session spend health router].freeze
      ESCAPES = { "<" => "\\u003c", "\u2028" => "\\u2028", "\u2029" => "\\u2029" }.freeze
      READOUTS = [
        %w[sessions Sessions],
        %w[tokens Tokens],
        ["failed", "Failed calls", "Failed"],
        ["gaps", "Capture gaps", "Gaps"]
      ].freeze
      PAGES = [%w[sessions Sessions], %w[spend Spend], %w[health Health]].freeze
      SKELETON_ROWS = 8

      class << self
        def render(dataset)
          head = [read("theme-boot.js"), read_vendor(ZOOM, "ui-zoom-boot.js")]
          body = SCRIPTED.map { |id| read_vendor(id, "#{short(id)}.js") }
          body += APP.map { |name| read(File.join("app", "#{name}.js")) }
          styles = [read("themes.css")]
          styles += STYLED.map { |id| read_vendor(id, "#{short(id)}.css") }
          styles << read("app.css")
          document(
            head: head.map { |source| script(source) },
            body: body.map { |source| script(source) },
            style: stylesheet(styles.join("\n")),
            data: encode(dataset),
            policy: policy(head + body)
          )
        end

        private

        def short(id)
          id.split(".").last
        end

        def read(relative)
          File.binread(File.join(WEB, relative)).force_encoding(Encoding::UTF_8)
        end

        def read_vendor(id, file)
          File.binread(File.join(VENDOR, id, file)).force_encoding(Encoding::UTF_8)
        end

        def script(source)
          raise ArgumentError, "a dashboard script closes its own element" if source.downcase.include?("</script")

          "<script>#{source}</script>"
        end

        def stylesheet(source)
          raise ArgumentError, "a dashboard stylesheet closes its own element" if source.downcase.include?("</style")

          "<style>\n#{source}</style>"
        end

        def encode(dataset)
          JSON.generate(dataset).gsub(/[<\u2028\u2029]/, ESCAPES)
        end

        def policy(sources)
          hashes = sources.map { |source| ["'sha256-", Digest::SHA256.base64digest(source), "'"].join }.uniq
          [
            "default-src 'none'",
            "script-src #{hashes.join(' ')}",
            "style-src 'unsafe-inline'",
            "img-src data:",
            "base-uri 'none'",
            "form-action 'none'",
            "connect-src 'none'"
          ].join("; ")
        end

        def document(head:, body:, style:, data:, policy:)
          [
            "<!doctype html>",
            "<html lang=\"en\" data-theme=\"minimal-dark\">",
            "<head>",
            "<meta charset=\"utf-8\">",
            "<meta http-equiv=\"Content-Security-Policy\" content=\"#{policy}\">",
            "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">",
            "<title>Sessions - tellem</title>",
            "<link rel=\"icon\" href=\"data:,\">",
            *head,
            style,
            "<noscript><style>.t-loading { display: none; } .t-tools { display: none; } .t-main[aria-busy=\"true\"] ~ .t-footer { visibility: visible; }</style></noscript>",
            "</head>",
            "<body>",
            *shell,
            "<script type=\"application/json\" id=\"tellem-data\">#{data}</script>",
            *body,
            "</body>",
            "</html>",
            ""
          ].join("\n")
        end

        def shell
          [
            "<div class=\"t-shell\">",
            "<div class=\"t-frame rui-ui-zoom-fill-height\">",
            "<a class=\"t-skip\" id=\"t-skip\" href=\"#t-main\">Skip to content</a>",
            "<p class=\"t-sr\" id=\"t-announce\" role=\"status\"></p>",
            *header,
            *rail,
            *main,
            *footer,
            "</div>",
            "</div>"
          ]
        end

        def header
          [
            "<header class=\"t-header\">",
            "<h1 class=\"t-brand\">tellem</h1>",
            "<div class=\"t-band\">",
            "<span class=\"t-band__bridge\"></span>",
            *READOUTS.map { |key, label, brief| readout(key, label, brief) },
            "<span class=\"t-band__cap\"></span>",
            "</div>",
            "</header>"
          ]
        end

        def readout(key, label, brief)
          "<div class=\"t-readout\" data-readout=\"#{key}\" role=\"group\" aria-label=\"#{label}\">" \
            "<span class=\"t-readout__label\">#{readout_label(label, brief)}</span>" \
            "<span class=\"t-readout__value\"></span>" \
            "<span class=\"t-readout__change\"></span></div>"
        end

        def readout_label(label, brief)
          return label unless brief

          "<span class=\"t-readout__long\">#{label}</span><span class=\"t-readout__short\">#{brief}</span>"
        end

        def rail
          [
            "<nav class=\"t-rail\" aria-label=\"Pages\">",
            *PAGES.map { |key, label| pill(key, label) },
            "<span class=\"t-rail__fill\"></span>",
            "</nav>"
          ]
        end

        def pill(key, label)
          "<a class=\"t-pill\" href=\"#/#{key}\" data-page=\"#{key}\"><span class=\"t-pill__face\">#{label}</span></a>"
        end

        def main
          [
            "<main class=\"t-main\" id=\"t-main\" tabindex=\"-1\" data-density=\"cockpit\" aria-busy=\"true\">",
            "<div class=\"t-toolbar\" id=\"t-toolbar\" data-density=\"cockpit\" hidden></div>",
            "<div class=\"t-attention\" id=\"t-attention\" hidden></div>",
            "<div class=\"t-pending\" id=\"t-pending\">",
            skeleton,
            "</div>",
            "<div class=\"t-view\" id=\"t-view\"></div>",
            "<noscript><p class=\"t-damaged\">This page needs JavaScript to draw tellem data.</p></noscript>",
            "</main>"
          ]
        end

        def skeleton
          "<div class=\"rui-loading-skeleton t-loading\" data-variant=\"rows\">" \
            "<span class=\"rui-loading-skeleton__status\" role=\"status\">Reading data</span>" \
            "<div class=\"rui-loading-skeleton__shapes\" aria-hidden=\"true\">#{'<span></span>' * SKELETON_ROWS}</div></div>"
        end

        def footer
          [
            "<footer class=\"t-footer\">",
            "<span class=\"t-elbow\"></span>",
            "<div class=\"t-footband\">",
            "<span class=\"t-band__bridge\"></span>",
            "<span class=\"t-segment\" id=\"t-asof\"></span>",
            "<span class=\"t-segment\" id=\"t-kind\"></span>",
            "<span class=\"t-band__fill\"></span>",
            "<div class=\"t-tools\">",
            "<span id=\"t-theme\"></span>",
            read_vendor(ZOOM, "ui-zoom.html").strip,
            "</div>",
            "<span class=\"t-band__cap\"></span>",
            "</div>",
            "</footer>"
          ]
        end
      end
    end
  end
end
