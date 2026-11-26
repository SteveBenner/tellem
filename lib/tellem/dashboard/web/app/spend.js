(function () {
  "use strict";
  var T = window.TELLEM;
  var F = T.format;
  var S = T.shell;
  var TOP = 10;
  var TRENDS = [
    { value: "total_tokens", label: "Total" },
    { value: "input_tokens", label: "Input" },
    { value: "output_tokens", label: "Output" },
    { value: "cache_read_input_tokens", label: "Cache read" }
  ];
  var DIMENSIONS = [
    { value: "model", label: "Model" },
    { value: "agent_type", label: "Agent type" },
    { value: "repository", label: "Repository" },
    { value: "persona", label: "Persona" },
    { value: "effort", label: "Effort" }
  ];
  var COLUMNS = [
    ["total", "Total", "total_tokens"],
    ["input", "Input", "input_tokens"],
    ["output", "Output", "output_tokens"],
    ["cache_read", "Cache read", "cache_read_input_tokens"],
    ["cache_write", "Cache write", "cache_creation_input_tokens"],
    ["reasoning", "Reasoning", "reasoning_tokens"]
  ];
  var UNITS = [[1e9, "tokens, billions"], [1e6, "tokens, millions"], [1e3, "tokens, thousands"]];
  var SORT_KEYS = ["name", "requests"].concat(COLUMNS.map(function (column) { return column[0]; }), ["cost"]);

  function known(value) {
    return value !== null && value !== undefined;
  }

  function nameOf(data, dimension, row) {
    var session = data.sessions[row[1]];
    if (dimension === "repository") {
      return session.repoName;
    }
    if (dimension === "model") {
      return data.word("models", row[4]) || F.UNKNOWN;
    }
    if (dimension === "effort") {
      return data.word("efforts", row[5]) || F.UNKNOWN;
    }
    if (dimension === "persona") {
      return data.word("personas", row[6]) || F.UNKNOWN;
    }
    var agent = session.agents[row[2]];
    if (agent && agent.key === "main") {
      return "main";
    }
    return data.word("agent_types", row[3]) || F.UNKNOWN;
  }

  function grouped(data, rows, dimension) {
    var groups = new Map();
    rows.forEach(function (row) {
      var key = dimension === "repository" ? data.sessions[row[1]].repo : nameOf(data, dimension, row);
      var group = groups.get(key);
      if (!group) {
        group = { name: nameOf(data, dimension, row), total: data.blank() };
        groups.set(key, group);
      }
      data.add(group.total, row);
    });
    return Array.from(groups.values());
  }

  function buckets(data, state, rows) {
    var span = data.range(state.window, false);
    var hourly = state.window === "24h";
    var list = [];
    var index = {};
    for (var hour = span[0]; hour <= span[1]; hour += 1) {
      var at = data.since + hour * T.data.HOUR;
      var label = hourly ? F.clock(at) : F.monthDay(at);
      var key = hourly ? hour : label;
      var bucket = list[list.length - 1];
      if (!bucket || bucket.key !== key) {
        bucket = { key: key, label: label, total: data.blank() };
        list.push(bucket);
      }
      index[hour] = bucket;
    }
    var start = data.since + span[0] * T.data.HOUR;
    var opening = new Date(start * 1000);
    if (!hourly && (opening.getHours() || opening.getMinutes())) {
      list[0].label = list[0].label + " from " + F.clock(start);
      list[0].partial = true;
    }
    rows.forEach(function (row) {
      if (index[row[0]]) {
        data.add(index[row[0]].total, row);
      }
    });
    return list;
  }

  function chart(data, state, rows) {
    var list = buckets(data, state, rows);
    var trend = TRENDS.filter(function (entry) { return entry.value === state.trend; })[0];
    var exact = list.map(function (bucket) {
      return bucket.total.rows === 0 ? 0 : data.counter(bucket.total, trend.value);
    });
    var most = exact.reduce(function (top, value) { return known(value) && value > top ? value : top; }, 0);
    var divisor = 1;
    var unit = "tokens";
    for (var i = 0; i < UNITS.length; i += 1) {
      if (most >= UNITS[i][0]) {
        divisor = UNITS[i][0];
        unit = UNITS[i][1];
        break;
      }
    }
    var labels = list.map(function (bucket, at) {
      return at === list.length - 1 ? bucket.label + " so far" : bucket.label;
    });
    var info = T.data.WINDOWS[state.window];
    var opening = F.utcOffset(data.since + data.range(state.window, false)[0] * T.data.HOUR);
    var closing = F.utcOffset(data.asOf);
    var zone = opening === closing ? closing : opening + " to " + closing;
    var partial = list[0].partial ? "first and last periods are partial and counted in the totals" : "the last period is partial and counted in the totals";
    var node = S.rui("composite.chart.time-series", {
      form: "columns", labels: labels, unit: unit, in_progress: false,
      series: [{ name: trend.label, focus: true, values: exact.map(function (value) { return known(value) ? value / divisor : null; }) }],
      caption: trend.label + " tokens per " + (state.window === "24h" ? "hour" : "day") + ", " + info.label + ", local time (" + zone + "); " + partial
    });
    var drawn = node.querySelectorAll(".rui-time-series__col");
    if (drawn.length && known(exact[exact.length - 1])) {
      drawn[drawn.length - 1].classList.add("rui-time-series__col--progress");
    }
    if (drawn.length && list[0].partial && known(exact[0])) {
      drawn[0].classList.add("rui-time-series__col--progress");
    }
    var head = node.querySelectorAll(".rui-time-series__table thead th")[1];
    if (head) {
      head.textContent = trend.label + " (tokens)";
    }
    Array.prototype.forEach.call(node.querySelectorAll(".rui-time-series__table tbody td"), function (cell, at) {
      cell.textContent = F.integer(exact[at]);
    });
    Array.prototype.forEach.call(node.querySelectorAll(".rui-time-series__label"), function (text) {
      text.title = text.textContent;
    });
    var toggle = node.querySelector(".rui-time-series__toggle");
    if (toggle) {
      toggle.title = "Show or hide the chart data";
      toggle.addEventListener("click", function () {
        state.trendData = toggle.getAttribute("aria-expanded") === "true";
      });
      if (state.trendData) {
        toggle.click();
        state.trendData = true;
      }
    }
    return node;
  }

  function ranked(data, groups, whole) {
    var top = groups.slice().sort(function (a, b) {
      var left = data.counter(a.total, "total_tokens");
      var right = data.counter(b.total, "total_tokens");
      if (left === right) {
        return a.name.localeCompare(b.name);
      }
      if (left === null || right === null) {
        return left === null ? 1 : -1;
      }
      return right - left;
    }).slice(0, TOP);
    var items = top.map(function (group) {
      var value = data.counter(group.total, "total_tokens");
      var share = known(value) && whole > 0 ? value / whole : null;
      var percent = share === null ? "" : " (" + (share > 0 && share < 0.005 ? "<1" : Math.round(share * 100)) + "%)";
      var entry = { label: group.name, value: F.compact(value) + percent };
      if (share !== null) {
        entry.share = share;
      }
      return entry;
    });
    var node = S.rui("composite.data.ranked-list", { items: items, empty: "No usage in this window", value_label: "Total tokens" });
    Array.prototype.forEach.call(node.querySelectorAll(".rui-ranked-list__item"), function (line, at) {
      var value = data.counter(top[at].total, "total_tokens");
      line.querySelector(".rui-ranked-list__label").title = top[at].name;
      line.querySelector(".rui-ranked-list__value").title = known(value) ? F.integer(value) + " total tokens" : F.NOT_RECORDED;
    });
    return node;
  }

  function breakdown(app, groups, whole, label) {
    var data = app.data;
    var state = app.state;
    function numeric(key, caption, read, show) {
      var render = show || F.integer;
      return {
        key: key, label: caption, numeric: true, value: read,
        cell: function (r) { return render(read(r)); },
        title: function (r) { return render(read(r)); }
      };
    }
    var counters = COLUMNS.map(function (column) {
      return numeric(column[0], column[1], function (r) { return data.counter(r.total, column[2]); });
    });
    var name = {
      key: "name", label: "Name",
      value: function (r) { return r.name; },
      cell: function (r) { return r.name; },
      title: function (r) { return r.name; }
    };
    var requests = numeric("requests", "Requests", function (r) { return r.total.requests; });
    var cost = numeric("cost", "Cost", function (r) { return r.total.cost; }, F.money);
    var columns = [name, counters[0], requests].concat(counters.slice(1), [cost]);
    var footer = {
      name: { text: "Total" },
      requests: { text: F.integer(whole.requests) },
      cost: { text: F.money(whole.cost) }
    };
    COLUMNS.forEach(function (column) {
      footer[column[0]] = { text: F.integer(data.counter(whole, column[2])) };
    });
    return S.sortableTable({
      id: "spend", caption: "Usage by " + label.toLowerCase(), columns: columns, identity: "name",
      rows: groups, footer: footer, empty: "No usage in this window", sort: state.spendSort,
      remember: function (sort) {
        state.spendSort = sort;
        app.sync();
      }
    });
  }

  function create(app) {
    var data = app.data;
    var state = app.state;
    var node = S.el("section", "t-page t-page--spend");
    var heading = S.attrs(S.el("h2", "t-title", "Spend"), { tabindex: "-1" });
    var totals = S.el("div", "t-holder");
    var cost = S.el("p", "t-cost");
    var trendHolder = S.el("div", "t-chart");
    var listHolder = S.el("div", "t-rank");
    var tableHolder = S.el("div", "t-holder");
    var trend = S.segmented("Trend figure", TRENDS, state.trend, function (value) {
      state.trend = value;
      update();
      var picked = TRENDS.filter(function (entry) { return entry.value === value; })[0];
      S.announce(picked.label + " trend, " + F.count(trendHolder.querySelectorAll(".rui-time-series__col").length, "column", "columns"));
      app.sync();
    });
    var dimension = S.segmented("Group by", DIMENSIONS, state.dimension, function (value) {
      state.dimension = value;
      update(true);
      app.sync();
    });
    var trendSection = S.el("section", "t-section");
    S.add(trendSection, S.el("h3", "t-subtitle", "Trend"), trend.node, trendHolder);
    var splitSection = S.el("section", "t-section");
    S.add(splitSection, S.el("h3", "t-subtitle", "Breakdown"), dimension.node, listHolder, tableHolder);
    S.add(node, heading, totals, cost, trendSection, splitSection);

    function update(change) {
      trend.set(state.trend);
      dimension.set(state.dimension);
      var span = data.range(state.window, false);
      var rows = data.usageIn(span, state.repo);
      var whole = data.totalOf(rows);
      function tile(label, value) {
        return { label: label, value: known(value) ? F.compact(value) : F.NOT_RECORDED, exact: known(value) ? F.integer(value) : F.NOT_RECORDED };
      }
      totals.replaceChildren(S.figures([
        tile("Requests", whole.requests),
        tile("Input", data.counter(whole, "input_tokens")),
        tile("Output", data.counter(whole, "output_tokens")),
        tile("Cache read", data.counter(whole, "cache_read_input_tokens")),
        tile("Cache write", data.counter(whole, "cache_creation_input_tokens")),
        tile("Total", data.counter(whole, "total_tokens"))
      ], "Usage in the " + T.data.WINDOWS[state.window].label));
      cost.textContent = whole.cost === null
        ? "Cost was not recorded in this window"
        : "Cost " + F.money(whole.cost) + ", recorded for " + F.integer(whole.costed) + " of " + F.count(whole.requests, "request", "requests");
      trendHolder.replaceChildren(chart(data, state, rows));
      var groups = grouped(data, rows, state.dimension);
      var picked = DIMENSIONS.filter(function (entry) { return entry.value === state.dimension; })[0];
      listHolder.replaceChildren(ranked(data, groups, data.counter(whole, "total_tokens")));
      tableHolder.replaceChildren(breakdown(app, groups, whole, picked.label));
      if (change) {
        S.announce(picked.label + " breakdown, " + F.count(groups.length, "row", "rows") + ", " + F.count(whole.requests, "request", "requests"));
      }
    }

    update();
    return {
      name: "spend",
      title: "Spend",
      node: node,
      heading: heading,
      update: update,
      restore: function () {
        return false;
      }
    };
  }

  function values(options) {
    return options.map(function (option) { return option.value; });
  }

  T.spend = { create: create, SORT_KEYS: SORT_KEYS, TREND_KEYS: values(TRENDS), DIMENSION_KEYS: values(DIMENSIONS) };
})();
