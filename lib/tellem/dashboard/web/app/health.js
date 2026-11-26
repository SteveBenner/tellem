(function () {
  "use strict";
  var T = window.TELLEM;
  var F = T.format;
  var S = T.shell;

  function known(value) {
    return value !== null && value !== undefined;
  }

  function milliseconds(value) {
    return known(value) ? F.integer(value) + " ms" : F.NOT_RECORDED;
  }

  function text(key, label, read) {
    return {
      key: key, label: label,
      value: read,
      cell: function (r) { return read(r); },
      title: function (r) { return read(r); }
    };
  }

  function number(key, label, read, show, hint) {
    return {
      key: key, label: label, numeric: true, value: read,
      cell: function (r) { return show(read(r)); },
      title: function (r) { return (hint || show)(read(r)); }
    };
  }

  function section(title, body) {
    var node = S.el("section", "t-section");
    S.add(node, S.el("h3", "t-subtitle", title), body);
    return node;
  }

  function gapRows(data, gaps) {
    var groups = new Map();
    gaps.forEach(function (gap) {
      var key = gap[2] + "/" + gap[3];
      var row = groups.get(key);
      if (!row) {
        row = { cause: data.word("causes", gap[2]) || F.UNKNOWN, harness: data.word("harnesses", gap[3]) || F.UNKNOWN, count: 0 };
        groups.set(key, row);
      }
      row.count += gap[4];
    });
    return Array.from(groups.values());
  }

  function hostRows(data, span) {
    var totals = new Map();
    data.raw.hook_gaps.forEach(function (gap) {
      if (gap[0] >= span[0] && gap[0] <= span[1]) {
        totals.set(gap[1], (totals.get(gap[1]) || 0) + gap[2]);
      }
    });
    return Array.from(totals, function (pair) {
      return { cause: data.word("causes", pair[0]) || F.UNKNOWN, count: pair[1] };
    }).sort(function (a, b) {
      return a.cause.localeCompare(b.cause);
    });
  }

  function plain(spec, key, direction) {
    spec.rows = S.ordered(spec.rows, spec.columns, { key: key, direction: direction });
    return S.table(spec);
  }

  function create(app) {
    var data = app.data;
    var state = app.state;
    var node = S.el("section", "t-page t-page--health");
    var heading = S.attrs(S.el("h2", "t-title", "Health"), { tabindex: "-1" });
    var totals = S.el("div", "t-holder");
    var gaps = S.el("div", "t-holder");
    var hooks = S.el("div", "t-holder");
    var derivation = S.el("div", "t-holder");
    var host = S.el("div", "t-holder");
    S.add(node, heading, totals,
      section("Capture gaps", gaps),
      section("Hook timing", hooks),
      section("Derivation", derivation),
      section("Host hooks", host),
      S.el("p", "t-quiet", "The database mirror is not read by this page"));

    function update(change) {
      var span = data.range(state.window, false);
      var found = data.gapsIn(span, state.repo);
      var count = found.reduce(function (sum, gap) { return sum + gap[4]; }, 0);
      var timed = data.raw.hooks[state.window].filter(function (row) { return row[0] === state.repo; });
      var overall = timed.filter(function (row) { return row[1] === null && row[2] === null; })[0];
      var scoped = data.repos.filter(function (repo) { return state.repo === null || repo.index === state.repo; });
      var lagging = scoped.filter(function (repo) { return repo.status === "lagging"; }).length;
      var unreadable = scoped.filter(function (repo) { return repo.status === "unreadable"; }).length;
      function tile(label, value, note) {
        return { label: label, value: value, exact: value, note: note };
      }
      totals.replaceChildren(S.figures([
        tile("Capture gaps", F.integer(count)),
        tile("Hook p50", milliseconds(overall && overall[4])),
        tile("Hook p99", milliseconds(overall && overall[5]), "target below 50 ms"),
        tile("Lagging repos", F.integer(lagging), "current state"),
        tile("Unreadable repos", F.integer(unreadable), "current state")
      ], "Capture health"));

      gaps.replaceChildren(plain({
        id: "gaps", caption: "Capture gaps by cause", identity: "cause", empty: "No capture gaps in this window",
        rows: gapRows(data, found),
        columns: [
          text("cause", "Cause", function (r) { return r.cause; }),
          text("harness", "Harness", function (r) { return r.harness; }),
          number("count", "Count", function (r) { return r.count; }, F.integer)
        ]
      }, "count", "descending"));

      var timings = timed.filter(function (row) { return row[1] !== null || row[2] !== null; });
      function harness(r) {
        return data.word("harnesses", r[1]) || F.UNKNOWN;
      }
      hooks.replaceChildren(plain({
        id: "hooks", caption: "Hook timing by harness and event", identity: "event", empty: "No hook samples in this window",
        rows: timings,
        columns: [
          text("harness", "Harness", harness),
          text("event", "Event", function (r) { return r[2] || F.UNKNOWN; }),
          number("samples", "Samples", function (r) { return r[3]; }, F.integer),
          number("p50", "p50", function (r) { return r[4]; }, milliseconds),
          number("p99", "p99", function (r) { return r[5]; }, milliseconds),
          number("max", "Max", function (r) { return r[6]; }, milliseconds)
        ]
      }, "samples", "descending"));

      derivation.replaceChildren(plain({
        id: "derivation", caption: "Derivation by repository, current state", identity: "repository", empty: "No repositories recorded",
        rows: scoped,
        columns: [
          {
            key: "repository", label: "Repository",
            value: function (r) { return r.name; },
            cell: function (r) { return r.name; },
            title: function (r) { return r.path ? r.name + ", " + r.path : r.name; }
          },
          {
            key: "status", label: "Status",
            value: function (r) { return r.status; },
            cell: function (r) {
              if (r.status === "lagging") {
                return S.badge("lagging", "warn");
              }
              return r.status === "unreadable" ? S.badge("unreadable", "danger") : r.status;
            },
            title: function (r) { return r.status; }
          },
          number("derived", "Last derived", function (r) { return r.lastDerive; }, F.dateTime, F.fullTime),
          number("newest", "Newest record", function (r) { return r.newestRaw; }, F.dateTime, F.fullTime),
          number("lag", "Lag", function (r) { return r.lag; }, F.duration, F.exactDuration),
          number("torn", "Torn lines", function (r) { return r.torn; }, F.integer)
        ]
      }, "repository", "ascending"));

      host.replaceChildren(plain({
        id: "host", caption: "Host hook gaps", identity: "cause", empty: "No host hook gaps in this window",
        rows: hostRows(data, span),
        columns: [
          text("cause", "Cause", function (r) { return r.cause; }),
          number("count", "Count", function (r) { return r.count; }, F.integer)
        ]
      }, "count", "descending"));
      if (change) {
        S.announce([
          F.count(count, "capture gap", "capture gaps"),
          F.count(timings.length, "hook timing row", "hook timing rows"),
          F.count(scoped.length, "repository", "repositories")
        ].join(", "));
      }
    }

    update();
    return {
      name: "health",
      title: "Health",
      node: node,
      heading: heading,
      update: update,
      restore: function () {
        return false;
      }
    };
  }

  T.health = { create: create };
})();
