(function () {
  "use strict";
  var T = window.TELLEM;
  var F = T.format;
  var NS = "http://www.w3.org/2000/svg";
  var STORED_KEY = "tellem.dashboard.theme";
  var SCHEME_QUERY = "(prefers-color-scheme: light)";
  var SMALL_PRIOR = 10;
  var PERCENT_LIMIT = 999;
  var sequence = 0;

  var ICONS = {
    up: [["path", { d: "M12 19V5M5.5 11.5 12 5l6.5 6.5" }]],
    warning: [["path", { d: "M12 3.5 21.5 20h-19zM12 10v4.5M12 17.2v.1" }]],
    blocked: [["circle", { cx: "12", cy: "12", r: "8.5" }], ["path", { d: "M6 18 18 6" }]],
    closed: [["path", { d: "M9 5.5 15.5 12 9 18.5" }]],
    opened: [["path", { d: "M5.5 9 12 15.5 18.5 9" }]]
  };

  var THEMES = [
    { id: "apple-noir", label: "Apple Noir", shapes: [["path", { d: "M20 14.6A8 8 0 1 1 9.4 4a6.3 6.3 0 0 0 10.6 10.6Z" }]] },
    {
      id: "apple-austere", label: "Austere", shapes: [
        ["circle", { cx: "12", cy: "12", r: "4.2" }],
        ["path", { d: "M12 2v2.4M12 19.6V22M4.22 4.22l1.7 1.7M18.08 18.08l1.7 1.7M2 12h2.4M19.6 12H22M4.22 19.78l1.7-1.7M18.08 5.92l1.7-1.7" }]
      ]
    },
    {
      id: "tronwave", label: "Tronwave", shapes: [
        ["path", { d: "M12 2.5 20.2 7.25 20.2 16.75 12 21.5 3.8 16.75 3.8 7.25Z" }],
        ["path", { d: "M7 12q2.5-3.5 5 0t5 0" }]
      ]
    },
    {
      id: "minimal-dark", label: "Minimal Dark", shapes: [
        ["rect", { x: "5", y: "5", width: "14", height: "14" }],
        ["path", { d: "M12 5v14" }],
        ["path", { d: "M5 9.67 9.67 5M5 14.33 12 7.33M5 19l7-7M9.67 19 12 16.67", "stroke-width": "1.5" }]
      ]
    },
    {
      id: "minimal-light", label: "Minimal Light", shapes: [
        ["rect", { x: "5", y: "5", width: "14", height: "14" }],
        ["path", { d: "M12 5v14" }]
      ]
    }
  ];

  function el(tag, cls, text) {
    var node = document.createElement(tag);
    if (cls) {
      node.className = cls;
    }
    if (text !== undefined && text !== null) {
      node.textContent = String(text);
    }
    return node;
  }

  function attrs(node, values) {
    Object.keys(values).forEach(function (name) {
      if (values[name] !== null && values[name] !== undefined) {
        node.setAttribute(name, String(values[name]));
      }
    });
    return node;
  }

  function add(parent) {
    for (var i = 1; i < arguments.length; i += 1) {
      if (arguments[i]) {
        parent.appendChild(arguments[i]);
      }
    }
    return parent;
  }

  function drawing(shapes, size) {
    var node = document.createElementNS(NS, "svg");
    attrs(node, {
      viewBox: "0 0 24 24", width: size, height: size, fill: "none", stroke: "currentColor", "stroke-width": "2",
      "stroke-linecap": "round", "stroke-linejoin": "round", "aria-hidden": "true", focusable: "false"
    });
    shapes.forEach(function (shape) {
      node.appendChild(attrs(document.createElementNS(NS, shape[0]), shape[1]));
    });
    return node;
  }

  function icon(name) {
    return drawing(ICONS[name], 14);
  }

  function uid(name) {
    sequence += 1;
    return "t-" + sequence + "-" + name;
  }

  function kpi(tile) {
    var cell = el("div", "t-kpi");
    var value = el("span", "t-kpi__value", tile.value);
    value.title = tile.exact || tile.value;
    add(cell, el("span", "t-kpi__label", tile.label), value);
    if (tile.note) {
      cell.appendChild(el("span", "t-kpi__note", tile.note));
    }
    return cell;
  }

  function rui(id, args, emit) {
    return window.RUI.components[id].render(args, {
      uid: uid,
      emit: emit || function () {},
      compose: function (child, tile) {
        return kpi(tile);
      }
    });
  }

  function badge(text, tone) {
    return rui("primitive.display.badge", { text: text, tone: tone || "neutral" });
  }

  function figures(tiles, label) {
    var node = rui("composite.card.stat-row", { tiles: tiles });
    node.setAttribute("aria-label", label);
    return node;
  }

  function segmented(label, options, value, onChange) {
    var root = el("div", "t-seg");
    var labelId = uid("segment");
    var caption = attrs(el("span", "t-field__label", label), { id: labelId });
    var group = attrs(el("div", "t-seg__group"), { role: "radiogroup", "aria-labelledby": labelId });
    var current = value;
    var buttons = options.map(function (option, index) {
      var button = attrs(el("button", "t-seg__option", option.label), { type: "button", role: "radio" });
      button.addEventListener("click", function () {
        choose(index, false);
      });
      button.addEventListener("keydown", function (event) {
        var next = null;
        if (event.key === "ArrowRight" || event.key === "ArrowDown") {
          next = (index + 1) % options.length;
        } else if (event.key === "ArrowLeft" || event.key === "ArrowUp") {
          next = (index - 1 + options.length) % options.length;
        } else if (event.key === "Home") {
          next = 0;
        } else if (event.key === "End") {
          next = options.length - 1;
        }
        if (next !== null) {
          event.preventDefault();
          choose(next, true);
        }
      });
      group.appendChild(button);
      return button;
    });

    function paint() {
      options.forEach(function (option, index) {
        var on = option.value === current;
        buttons[index].setAttribute("aria-checked", on ? "true" : "false");
        if (on) {
          buttons[index].setAttribute("aria-current", "true");
        } else {
          buttons[index].removeAttribute("aria-current");
        }
        buttons[index].tabIndex = on ? 0 : -1;
      });
    }

    function choose(index, focus) {
      var changed = options[index].value !== current;
      current = options[index].value;
      paint();
      if (focus) {
        buttons[index].focus();
      }
      if (changed) {
        onChange(current);
      }
    }

    paint();
    add(root, caption, group);
    return {
      node: root,
      set: function (next) {
        current = next;
        paint();
      }
    };
  }

  function selectField(label, name, options, value, onChange) {
    var root = el("div", "t-select");
    var inner = null;
    var current = value;

    function draw(chosen) {
      current = chosen;
      var next = rui("primitive.input.select", { name: name, label: label, options: options, value: chosen, action: name }, function (action, values) {
        current = values[name];
        retitle(current);
        onChange(current);
      });
      if (inner) {
        root.replaceChild(next, inner);
      } else {
        root.appendChild(next);
      }
      inner = next;
      var items = inner.querySelectorAll("[role=option]");
      options.forEach(function (option, index) {
        items[index].title = option.label;
      });
      retitle(chosen);
    }

    function retitle(chosen) {
      var match = options.filter(function (option) {
        return option.value === chosen;
      })[0];
      var button = inner.querySelector("[role=combobox]");
      button.title = match ? match.label : label;
    }

    draw(value);
    return {
      node: root,
      reset: draw,
      set: function (chosen) {
        if (chosen !== current) {
          draw(chosen);
        }
      }
    };
  }

  function table(spec) {
    var wrap = attrs(el("div", "t-table t-table--" + spec.id), { "data-density": "cockpit" });
    var columns = spec.columns.map(function (column) {
      return {
        key: column.key, label: column.label, type: column.numeric ? "number" : "text", align: column.numeric ? "end" : "start",
        sortable: Boolean(spec.onSort), identity: column.key === spec.identity
      };
    });
    var rows = spec.rows.map(function (row, index) {
      var out = { _row: index };
      spec.columns.forEach(function (column) {
        var sorted = spec.sort && spec.sort.key === column.key;
        out[column.key] = sorted ? (spec.sort.direction === "descending" ? spec.rows.length - index : index + 1) : 1;
      });
      return out;
    });
    var node = rui("composite.data.table", {
      columns: columns, rows: rows, row_key: "_row", density: "cockpit", caption: spec.caption, empty: spec.empty || "No rows",
      sort: spec.sort ? { key: spec.sort.key, direction: spec.sort.direction } : null,
      row_action: spec.action ? "open" : null, on_sort: spec.onSort ? "sort" : null
    }, function (action, detail) {
      if (action === "sort") {
        spec.onSort(detail.key);
      } else if (action === "open") {
        spec.action.run(spec.rows[detail._row]);
      }
    });
    var spoken = node.querySelector("[aria-live]");
    spoken.removeAttribute("role");
    spoken.removeAttribute("aria-live");
    wrap.appendChild(node);
    var heads = node.querySelectorAll("thead th");
    spec.columns.forEach(function (column, index) {
      heads[index].classList.add("t-col-" + column.key);
      var button = heads[index].querySelector("button");
      if (button) {
        button.title = "Sort by " + column.label;
        button.setAttribute("data-column", column.key);
      }
    });
    if (spec.action) {
      heads[spec.columns.length].classList.add("t-col-action");
    }
    var body = node.querySelectorAll("tbody tr");
    spec.rows.forEach(function (row, at) {
      var line = body[at];
      spec.columns.forEach(function (column, index) {
        var cell = line.children[index];
        var content = column.cell(row);
        if (typeof content === "string") {
          content = el("span", "t-clip", content);
        }
        cell.replaceChildren(content);
        cell.classList.add("t-col-" + column.key);
        cell.title = column.title ? column.title(row) : cell.textContent;
      });
      if (spec.action) {
        var holder = line.children[spec.columns.length];
        var open = holder.querySelector("button");
        holder.classList.add("t-col-action");
        open.setAttribute("aria-label", spec.action.name(row));
        open.title = spec.action.name(row);
        open.setAttribute("data-row", String(spec.action.id(row)));
      }
    });
    if (spec.footer && spec.rows.length) {
      var foot = el("tfoot");
      var total = el("tr", "rui-table__row");
      spec.columns.forEach(function (column, index) {
        var entry = spec.footer[column.key] || { text: "" };
        var cell = el(index === 0 ? "th" : "td", "rui-table__cell t-col-" + column.key + (column.numeric ? " rui-table__cell--end rui-table__cell--figures" : ""));
        if (index === 0) {
          cell.setAttribute("scope", "row");
        }
        cell.appendChild(el("span", "t-clip", entry.text));
        cell.title = entry.title || entry.text;
        total.appendChild(cell);
      });
      foot.appendChild(total);
      node.querySelector("table").appendChild(foot);
    }
    return wrap;
  }

  function nextSort(sort, key, columns) {
    if (sort.key !== key) {
      var numeric = columns.some(function (column) { return column.key === key && column.numeric; });
      return { key: key, direction: numeric ? "descending" : "ascending" };
    }
    return { key: key, direction: sort.direction === "ascending" ? "descending" : "ascending" };
  }

  function ordered(rows, columns, sort) {
    var column = columns.filter(function (entry) {
      return entry.key === sort.key;
    })[0];
    var sign = sort.direction === "ascending" ? 1 : -1;
    return rows.map(function (row, index) {
      return { row: row, index: index, value: column.value(row) };
    }).sort(function (a, b) {
      var ae = a.value === null || a.value === undefined;
      var be = b.value === null || b.value === undefined;
      if (ae || be) {
        return ae === be ? a.index - b.index : (ae ? 1 : -1);
      }
      var compared = typeof a.value === "number" ? a.value - b.value : a.value.localeCompare(b.value, undefined, { numeric: true });
      return compared !== 0 ? sign * compared : a.index - b.index;
    }).map(function (entry) {
      return entry.row;
    });
  }

  function announce(text) {
    var region = document.getElementById("t-announce");
    if (region.textContent !== text) {
      region.textContent = text;
    }
  }

  function sortPhrase(columns, sort) {
    var column = columns.filter(function (entry) {
      return entry.key === sort.key;
    })[0];
    var words = column.order || (column.numeric ? ["lowest first", "highest first"] : ["A to Z", "Z to A"]);
    return "Sorted by " + column.label + ", " + words[sort.direction === "ascending" ? 0 : 1];
  }

  function sortableTable(spec) {
    var holder = el("div", "t-holder");
    var sort = spec.sort;
    var noun = spec.noun || ["row", "rows"];

    function draw(focus) {
      var rows = ordered(spec.rows, spec.columns, sort);
      var options = {};
      Object.keys(spec).forEach(function (key) {
        options[key] = spec[key];
      });
      options.rows = rows;
      options.sort = sort;
      options.onSort = function (key) {
        sort = nextSort(sort, key, spec.columns);
        if (spec.remember) {
          spec.remember(sort);
        }
        draw(key);
        announce(sortPhrase(spec.columns, sort) + ", " + F.count(spec.rows.length, noun[0], noun[1]));
      };
      holder.replaceChildren(table(options));
      if (focus) {
        var button = holder.querySelector("button[data-column=\"" + focus + "\"]");
        if (button) {
          button.focus();
        }
      }
    }

    draw(null);
    return holder;
  }

  function pager(label, onMove) {
    var root = attrs(el("div", "t-pager"), { role: "group", "aria-label": label });
    var previous = attrs(el("button", "t-button", "Previous"), { type: "button" });
    var next = attrs(el("button", "t-button", "Next"), { type: "button" });
    var status = el("span", "t-pager__status");
    [[previous, -1], [next, 1]].forEach(function (pair) {
      pair[0].addEventListener("click", function () {
        if (pair[0].getAttribute("aria-disabled") !== "true") {
          onMove(pair[1]);
        }
      });
    });
    add(root, previous, next, status);
    return {
      node: root,
      update: function (page, pages, total, one, many) {
        previous.setAttribute("aria-disabled", page <= 0 ? "true" : "false");
        next.setAttribute("aria-disabled", page >= pages - 1 ? "true" : "false");
        var text = "Page " + (page + 1) + " of " + pages + ", " + F.count(total, one, many);
        if (status.textContent !== text) {
          status.textContent = text;
        }
        return text;
      }
    };
  }

  function change(now, before, windowInfo) {
    if (!windowInfo.prior) {
      return { text: "", spoken: "no earlier period", rise: false };
    }
    if (F.missing(now) || F.missing(before)) {
      return { text: "", spoken: "", rise: false };
    }
    if (now === 0 && before === 0) {
      return { text: "", spoken: "no change " + windowInfo.prior, rise: false };
    }
    var difference = now - before;
    var text;
    var shown = null;
    if (before === 0) {
      text = "new";
    } else if (before < SMALL_PRIOR) {
      text = (difference > 0 ? "+" : "") + F.integer(difference);
    } else {
      var percent = Math.round(difference / before * 100);
      text = (percent > 0 ? "+" : "") + percent + "%";
      shown = percent > PERCENT_LIMIT ? ">" + PERCENT_LIMIT + "%" : null;
    }
    return { text: shown || text, spoken: text + " " + windowInfo.prior + ", prior value " + F.integer(before), rise: difference > 0 };
  }

  function readouts(data, state) {
    var info = T.data.WINDOWS[state.window];
    var span = data.range(state.window, false);
    var prior = data.range(state.window, true);

    function measure(at) {
      if (!at) {
        return null;
      }
      return {
        sessions: data.sessionsIn(at, state.repo).length,
        tokens: data.counter(data.totalOf(data.usageIn(at, state.repo)), "total_tokens"),
        failed: data.failuresIn(at, state.repo),
        gaps: data.gapsIn(at, state.repo).reduce(function (sum, gap) { return sum + gap[4]; }, 0)
      };
    }

    var now = measure(span);
    var before = measure(prior);
    [
      ["sessions", "Sessions", false],
      ["tokens", "Tokens", false],
      ["failed", "Failed calls", true],
      ["gaps", "Capture gaps", true]
    ].forEach(function (entry) {
      var node = document.querySelector("[data-readout=\"" + entry[0] + "\"]");
      var value = now[entry[0]];
      var moved = change(value, before && before[entry[0]], info);
      var compactForm = entry[0] === "tokens" || (value !== null && value >= 10000);
      node.querySelector(".t-readout__value").textContent = compactForm ? F.compact(value) : F.integer(value);
      var slot = node.querySelector(".t-readout__change");
      slot.replaceChildren();
      var worse = entry[2] && moved.rise && Boolean(info.prior);
      if (value !== null && moved.text) {
        if (worse) {
          slot.appendChild(icon("up"));
        }
        slot.appendChild(el("span", null, moved.text));
      }
      var spoken = entry[1] + " " + F.integer(value) + (moved.spoken ? ", " + moved.spoken : "") + (worse ? ", worse" : "");
      node.setAttribute("aria-label", spoken);
      node.title = spoken;
    });
  }

  function chip(kind, name, text, route) {
    var link = route(el("a", "t-chip t-chip--" + kind), "#/health");
    add(link, icon(name), el("span", "t-chip__text", text));
    return link;
  }

  function attention(data, state, route) {
    var host = document.getElementById("t-attention");
    var gaps = data.gapsIn(data.range(state.window, false), state.repo).reduce(function (sum, gap) { return sum + gap[4]; }, 0);
    var scoped = data.repos.filter(function (repo) { return state.repo === null || repo.index === state.repo; });
    var lagging = scoped.filter(function (repo) { return repo.status === "lagging"; }).length;
    var unreadable = scoped.filter(function (repo) { return repo.status === "unreadable"; }).length;
    host.replaceChildren();
    if (gaps) {
      host.appendChild(chip("warn", "warning", F.count(gaps, "capture gap", "capture gaps") + " in this window", route));
    }
    if (lagging) {
      host.appendChild(chip("warn", "warning", F.count(lagging, "repository", "repositories") + " lagging by more than 900 seconds", route));
    }
    if (unreadable) {
      host.appendChild(chip("danger", "blocked", F.count(unreadable, "repository", "repositories") + " could not be read", route));
    }
    if (!host.firstChild) {
      host.appendChild(el("p", "t-quiet", "No capture problems in this window"));
    }
  }

  function toolbar(data, state, onChange) {
    var host = document.getElementById("t-toolbar");
    function chosenRepo() {
      return state.repo === null ? "all" : String(state.repo);
    }
    function chosenHarness() {
      return state.harness === null ? "all" : state.harness;
    }
    var windows = segmented("Window", [{ value: "24h", label: "24h" }, { value: "7d", label: "7d" }, { value: "30d", label: "30d" }], state.window, function (value) {
      state.window = value;
      onChange();
    });
    var repoOptions = [{ value: "all", label: "All repositories" }].concat(data.repos.map(function (repo) {
      return { value: String(repo.index), label: repo.name };
    }));
    var repos = selectField("Repository", "repository", repoOptions, chosenRepo(), function (value) {
      state.repo = value === "all" ? null : Number(value);
      onChange();
    });
    var harnessOptions = [{ value: "all", label: "All harnesses" }].concat(data.raw.dict.harnesses.map(function (name) {
      return { value: name, label: name };
    }));
    var harness = selectField("Harness", "harness", harnessOptions, chosenHarness(), function (value) {
      state.harness = value === "all" ? null : value;
      onChange();
    });
    var field = el("div", "t-search");
    var searchId = uid("search");
    var label = attrs(el("label", "t-field__label", "Search sessions"), { "for": searchId });
    var input = attrs(el("input", "t-search__input"), { id: searchId, type: "search", autocomplete: "off", spellcheck: "false" });
    input.value = state.search;
    input.addEventListener("input", function () {
      state.search = input.value;
      onChange();
    });
    add(field, label, input);
    host.replaceChildren(windows.node, repos.node, harness.node, field);
    return {
      page: function (name) {
        harness.node.hidden = name !== "sessions";
        field.hidden = name !== "sessions";
      },
      setWindow: function (value) {
        windows.set(value);
      },
      sync: function () {
        windows.set(state.window);
        repos.set(chosenRepo());
        harness.set(chosenHarness());
        if (input.value !== state.search) {
          input.value = state.search;
        }
      },
      clear: function () {
        repos.reset("all");
        harness.reset("all");
        input.value = "";
      }
    };
  }

  function storedTheme() {
    try {
      var value = localStorage.getItem(STORED_KEY);
      return THEMES.some(function (theme) { return theme.id === value; }) ? value : null;
    } catch (error) {
      return null;
    }
  }

  function themeToggle() {
    var host = document.getElementById("t-theme");
    var button = attrs(el("button", "theme-toggle"), { type: "button" });

    function position() {
      var id = document.documentElement.getAttribute("data-theme");
      for (var i = 0; i < THEMES.length; i += 1) {
        if (THEMES[i].id === id) {
          return i;
        }
      }
      return 0;
    }

    function paint() {
      var at = position();
      var current = THEMES[at];
      var next = THEMES[(at + 1) % THEMES.length];
      button.title = "Theme: " + current.label + ". Click for " + next.label + ".";
      button.setAttribute("aria-label", "Theme: " + current.label + ". Click to switch to " + next.label + ".");
      button.replaceChildren(drawing(current.shapes, 18));
    }

    button.addEventListener("click", function () {
      var next = THEMES[(position() + 1) % THEMES.length].id;
      document.documentElement.setAttribute("data-theme", next);
      try {
        localStorage.setItem(STORED_KEY, next);
      } catch (error) {
        button.setAttribute("data-unsaved", "true");
      }
      paint();
    });
    try {
      window.matchMedia(SCHEME_QUERY).addEventListener("change", function (event) {
        if (storedTheme() === null && !button.hasAttribute("data-unsaved")) {
          document.documentElement.setAttribute("data-theme", event.matches ? "minimal-light" : "minimal-dark");
          paint();
        }
      });
    } catch (error) {
      button.removeAttribute("data-unsaved");
    }
    paint();
    host.replaceChildren(button);
  }

  function footer(data) {
    document.getElementById("t-asof").textContent = "As of " + F.dateTime(data.asOf);
    document.getElementById("t-asof").title = "As of " + F.fullTime(data.asOf) + " local time";
    var kind = data.share ? "Share copy" : "Private file";
    document.getElementById("t-kind").textContent = kind;
    document.getElementById("t-kind").title = kind;
  }

  T.shell = {
    el: el, attrs: attrs, add: add, icon: icon, uid: uid, rui: rui, badge: badge, figures: figures, segmented: segmented,
    selectField: selectField, table: table, sortableTable: sortableTable, ordered: ordered, nextSort: nextSort, pager: pager,
    announce: announce, sortPhrase: sortPhrase,
    readouts: readouts, attention: attention, toolbar: toolbar, themeToggle: themeToggle, footer: footer
  };
})();
