(function () {
  "use strict";
  window.RUI = window.RUI || {};
  RUI.components = RUI.components || {};

  var ICONS = { table: "M224,48H32a8,8,0,0,0-8,8V192a16,16,0,0,0,16,16H216a16,16,0,0,0,16-16V56A8,8,0,0,0,224,48ZM40,112H80v32H40Zm56,0H216v32H96ZM216,64V96H40V64ZM40,160H80v32H40Zm176,32H96V160H216v32Z" };
  var DASHES = ["6 4", "2 3", "8 3 2 3"];
  var NS = "http://www.w3.org/2000/svg";
  var STEPS = [1, 2, 2.5, 5];

  function el(tag, cls, text) {
    var node = document.createElement(tag);
    if (cls) {
      node.className = cls;
    }
    if (text !== undefined) {
      node.textContent = text;
    }
    return node;
  }

  function svg(tag) {
    return document.createElementNS(NS, tag);
  }

  function icon(name, cls) {
    var node = svg("svg");
    node.setAttribute("class", (cls ? cls + " " : "") + "rui-time-series__icon");
    node.setAttribute("viewBox", "0 0 256 256");
    node.setAttribute("fill", "currentColor");
    node.setAttribute("aria-hidden", "true");
    node.setAttribute("focusable", "false");
    var path = svg("path");
    path.setAttribute("d", ICONS[name]);
    node.appendChild(path);
    return node;
  }

  function isNum(v) {
    return typeof v === "number" && isFinite(v);
  }

  function round(v) {
    return Math.round(v * 100) / 100;
  }

  function niceStep(span) {
    var k = Math.pow(10, Math.floor(Math.log(span) / Math.LN10) - 1);
    for (var e = 0; e < 4; e += 1) {
      for (var i = 0; i < STEPS.length; i += 1) {
        var step = STEPS[i] * k * Math.pow(10, e);
        if (Math.ceil(span / step - 1e-9) <= 4) {
          return step;
        }
      }
    }
    return k * 1000;
  }

  function scale(values, form, baseline) {
    var all = values.slice();
    if (isNum(baseline)) {
      all.push(baseline);
    }
    var max = Math.max.apply(null, all);
    var min = Math.min.apply(null, all);
    var start = Math.min(0, min);
    if (form === "line" && min > 0 && min > 0.5 * max) {
      start = min;
    }
    if (max <= start) {
      max = start + 1;
    }
    var step = niceStep(max - start);
    var lo = Math.floor(start / step + 1e-9) * step;
    var hi = Math.ceil(max / step - 1e-9) * step;
    if (hi <= lo) {
      hi = lo + step;
    }
    var ticks = [];
    for (var v = lo; v <= hi + step / 1000; v += step) {
      ticks.push(Number(v.toFixed(10)));
    }
    return { lo: lo, hi: hi, ticks: ticks };
  }

  function runs(values) {
    var out = [];
    var current = null;
    values.forEach(function (v, i) {
      if (isNum(v)) {
        if (!current) {
          current = [];
          out.push(current);
        }
        current.push(i);
      } else {
        current = null;
      }
    });
    return out;
  }

  function polyline(points, cls, dash) {
    var line = svg("polyline");
    line.setAttribute("class", cls);
    line.setAttribute("points", points.join(" "));
    line.setAttribute("vector-effect", "non-scaling-stroke");
    if (dash) {
      line.setAttribute("stroke-dasharray", dash);
    }
    return line;
  }

  function lineClass(entry) {
    return entry.focus ? "rui-time-series__line rui-time-series__line--focus" : "rui-time-series__line";
  }

  function at(node, y) {
    node.style.setProperty("--rui-time-series-y", round(y) + "%");
    return node;
  }

  function spread(entries) {
    var gap = 14;
    entries.sort(function (a, b) { return a.y - b.y; });
    entries.forEach(function (e, i) {
      if (i > 0 && e.y < entries[i - 1].y + gap) {
        e.y = entries[i - 1].y + gap;
      }
    });
    var over = entries.length ? entries[entries.length - 1].y - 100 : 0;
    if (over > 0) {
      entries.forEach(function (e) { e.y = Math.max(0, e.y - over); });
    }
    return entries;
  }

  RUI.components["composite.chart.time-series"] = {
    render: function (args, ctx) {
      var form = args.form === "columns" ? "columns" : "line";
      var labels = args.labels || [];
      var n = labels.length;
      var series = (args.series || []).slice(0, 4).map(function (s) {
        return { name: s.name, values: labels.map(function (_, i) { return (s.values || [])[i]; }), focus: s.focus === true };
      });
      var focusIndex = 0;
      series.forEach(function (s, i) {
        if (s.focus && !series.some(function (o, j) { return o.focus && j < i; })) {
          focusIndex = i;
        }
      });
      series.forEach(function (s, i) {
        s.focus = i === focusIndex;
      });
      var plotted = form === "columns" ? series.slice(focusIndex, focusIndex + 1) : series;
      var nums = [];
      plotted.forEach(function (s) {
        s.values.forEach(function (v) {
          if (isNum(v)) {
            nums.push(v);
          }
        });
      });
      var fmt = new Intl.NumberFormat(undefined, { maximumFractionDigits: 2 });

      var root = el("figure", "rui-time-series");
      root.setAttribute("data-rui-component", "composite.chart.time-series");

      if (n === 0 || nums.length === 0) {
        root.appendChild(el("p", "rui-time-series__empty", "No data"));
        root.appendChild(el("figcaption", "rui-time-series__caption", args.caption));
        return root;
      }

      var sc = scale(nums, form, args.baseline);
      function y(v) {
        return 100 - ((v - sc.lo) / (sc.hi - sc.lo)) * 100;
      }
      function x(i) {
        return i * 10 + 5;
      }

      var lineSeries = form === "line" ? plotted : [];
      var plot = el("div", "rui-time-series__plot" + (lineSeries.length > 0 ? " rui-time-series__plot--labeled" : ""));
      if (args.unit) {
        var unit = el("span", "rui-time-series__unit", args.unit);
        unit.setAttribute("aria-hidden", "true");
        plot.appendChild(unit);
      }

      var chart = svg("svg");
      chart.setAttribute("class", "rui-time-series__svg");
      chart.setAttribute("viewBox", "0 0 " + (n * 10) + " 100");
      chart.setAttribute("preserveAspectRatio", "none");
      chart.setAttribute("role", "img");
      chart.setAttribute("aria-label", args.caption);

      sc.ticks.forEach(function (t) {
        var grid = svg("line");
        grid.setAttribute("class", "rui-time-series__grid");
        grid.setAttribute("x1", "0");
        grid.setAttribute("x2", String(n * 10));
        grid.setAttribute("y1", String(round(y(t))));
        grid.setAttribute("y2", String(round(y(t))));
        grid.setAttribute("vector-effect", "non-scaling-stroke");
        chart.appendChild(grid);
      });

      if (form === "columns") {
        var column = plotted[0];
        var zero = y(0 < sc.lo ? sc.lo : 0);
        column.values.forEach(function (v, i) {
          if (!isNum(v)) {
            return;
          }
          var top = y(v);
          var rect = svg("rect");
          rect.setAttribute("class", "rui-time-series__col" + (args.in_progress && i === n - 1 ? " rui-time-series__col--progress" : ""));
          rect.setAttribute("x", String(i * 10 + 1.5));
          rect.setAttribute("width", "7");
          rect.setAttribute("y", String(round(Math.min(top, zero))));
          rect.setAttribute("height", String(round(Math.max(Math.abs(zero - top), 0.5))));
          chart.appendChild(rect);
        });
      } else {
        var context = 0;
        plotted.forEach(function (s) {
          if (!s.focus) {
            s.dash = DASHES[context];
            context += 1;
          }
        });
        plotted.slice().sort(function (a, b) {
          return (a.focus ? 1 : 0) - (b.focus ? 1 : 0);
        }).forEach(function (s) {
          runs(s.values).forEach(function (run) {
            var pts = run.map(function (i) { return x(i) + "," + round(y(s.values[i])); });
            if (pts.length === 1) {
              pts.push(pts[0]);
            }
            var endsLast = run[run.length - 1] === n - 1;
            if (args.in_progress && endsLast && run.length >= 2) {
              chart.appendChild(polyline(pts.slice(0, pts.length - 1), lineClass(s), s.dash));
              chart.appendChild(polyline(pts.slice(pts.length - 2), lineClass(s) + " rui-time-series__line--progress", "3 3"));
            } else {
              chart.appendChild(polyline(pts, lineClass(s), s.dash));
            }
          });
        });
      }

      if (isNum(args.baseline)) {
        var ref = svg("line");
        ref.setAttribute("class", "rui-time-series__ref");
        ref.setAttribute("x1", "0");
        ref.setAttribute("x2", String(n * 10));
        ref.setAttribute("y1", String(round(y(args.baseline))));
        ref.setAttribute("y2", String(round(y(args.baseline))));
        ref.setAttribute("vector-effect", "non-scaling-stroke");
        ref.setAttribute("stroke-dasharray", "4 4");
        chart.appendChild(ref);
      }
      plot.appendChild(chart);

      var overlay = el("div", "rui-time-series__overlay");
      overlay.setAttribute("aria-hidden", "true");
      sc.ticks.forEach(function (t) {
        overlay.appendChild(at(el("span", "rui-time-series__tick", fmt.format(t)), y(t)));
      });
      if (isNum(args.baseline)) {
        var refY = y(args.baseline);
        var refName = typeof args.baseline_label === "string" && args.baseline_label !== "" ? args.baseline_label : "Reference";
        overlay.appendChild(at(el("span", "rui-time-series__ref-label" + (refY < 12 ? " rui-time-series__ref-label--below" : ""), refName + " " + fmt.format(args.baseline)), refY));
      }
      var directs = [];
      lineSeries.forEach(function (s) {
        var last = null;
        s.values.forEach(function (v) {
          if (isNum(v)) {
            last = v;
          }
        });
        if (last !== null) {
          directs.push({ name: s.name, y: y(last) });
        }
      });
      spread(directs).forEach(function (d) {
        overlay.appendChild(at(el("span", "rui-time-series__direct", d.name), d.y));
      });
      plot.appendChild(overlay);
      root.appendChild(plot);

      var axis = el("div", "rui-time-series__labels");
      axis.setAttribute("aria-hidden", "true");
      var picks = [0];
      if (n > 2) {
        picks.push(Math.floor((n - 1) / 2));
      }
      if (n > 1) {
        picks.push(n - 1);
      }
      picks.forEach(function (i) {
        var text = labels[i] + (args.in_progress && i === n - 1 ? " (in progress)" : "");
        axis.appendChild(el("span", "rui-time-series__label", text));
      });
      root.appendChild(axis);

      var caption = el("figcaption", "rui-time-series__caption");
      caption.appendChild(document.createTextNode(args.caption));
      root.appendChild(caption);

      var tableId = ctx.uid("table");
      var toggle = el("button", "rui-time-series__toggle");
      toggle.type = "button";
      toggle.setAttribute("aria-expanded", "false");
      toggle.setAttribute("aria-controls", tableId);
      toggle.appendChild(icon("table"));
      var toggleText = el("span", "rui-time-series__toggle-text", "Show data");
      toggle.appendChild(toggleText);
      root.appendChild(toggle);

      var wrap = el("div", "rui-time-series__table-wrap");
      wrap.hidden = true;
      var table = el("table", "rui-time-series__table");
      table.id = tableId;
      table.hidden = true;
      table.appendChild(el("caption", "rui-time-series__sr", args.caption));
      var head = el("tr");
      var period = el("th", "", "Period");
      period.setAttribute("scope", "col");
      head.appendChild(period);
      series.forEach(function (s) {
        var th = el("th", "", args.unit ? s.name + " (" + args.unit + ")" : s.name);
        th.setAttribute("scope", "col");
        head.appendChild(th);
      });
      table.appendChild(el("thead")).appendChild(head);
      var body = el("tbody");
      labels.forEach(function (label, i) {
        var tr = el("tr");
        var th = el("th", "", label);
        th.setAttribute("scope", "row");
        tr.appendChild(th);
        series.forEach(function (s) {
          tr.appendChild(el("td", "", isNum(s.values[i]) ? fmt.format(s.values[i]) : "No data"));
        });
        body.appendChild(tr);
      });
      table.appendChild(body);
      wrap.appendChild(table);
      root.appendChild(wrap);

      toggle.addEventListener("click", function () {
        var open = toggle.getAttribute("aria-expanded") !== "true";
        toggle.setAttribute("aria-expanded", open ? "true" : "false");
        wrap.hidden = !open;
        table.hidden = !open;
        toggleText.textContent = open ? "Hide data" : "Show data";
      });
      return root;
    }
  };
})();
