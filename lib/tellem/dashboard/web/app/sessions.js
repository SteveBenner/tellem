(function () {
  "use strict";
  var T = window.TELLEM;
  var F = T.format;
  var S = T.shell;
  var PAGE_SIZE = 100;

  function sessionRoute(session) {
    return "#/session/" + session.route + "/agents";
  }

  function title(session) {
    return session.label || session.key;
  }

  function tokens(data, session) {
    return data.counter(session.total, "total_tokens");
  }

  function failureFigure(count) {
    var node = S.el("span", "t-failures" + (count > 0 ? " t-failures--some" : ""));
    if (count > 0) {
      node.appendChild(S.attrs(S.el("span", "t-diamond"), { "aria-hidden": "true" }));
    }
    node.appendChild(S.el("span", null, F.integer(count)));
    return node;
  }

  function columns(data, link) {
    return [
      {
        key: "started", label: "Started", numeric: false, order: ["oldest first", "newest first"],
        value: function (s) { return s.started; },
        cell: function (s) { return F.dateTime(s.started); },
        title: function (s) { return F.fullTime(s.started); }
      },
      {
        key: "repo", label: "Repository",
        value: function (s) { return s.repoName; },
        cell: function (s) { return s.repoName; },
        title: function (s) { return s.repoName; }
      },
      {
        key: "label", label: "Session",
        value: function (s) { return title(s); },
        cell: function (s) {
          var node = S.el("span", "t-session");
          var anchor = link(S.el("a", "t-link t-session__name"), sessionRoute(s));
          anchor.appendChild(S.el("span", "t-clip", title(s)));
          anchor.title = title(s);
          node.appendChild(anchor);
          if (s.open) {
            node.appendChild(S.badge("running"));
          }
          return node;
        },
        title: function (s) { return title(s); }
      },
      {
        key: "harness", label: "Harness",
        value: function (s) { return s.harness; },
        cell: function (s) { return s.harness || F.UNKNOWN; },
        title: function (s) { return s.harness || F.UNKNOWN; }
      },
      {
        key: "agents", label: "Agents", numeric: true,
        value: function (s) { return s.agents.length; },
        cell: function (s) { return F.integer(s.agents.length); },
        title: function (s) { return F.integer(s.agents.length); }
      },
      {
        key: "active", label: "Active", numeric: true,
        value: function (s) { return s.active; },
        cell: function (s) { return F.duration(s.active); },
        title: function (s) { return s.active === null ? F.NOT_RECORDED : "Time with at least one agent active: " + F.exactDuration(s.active); }
      },
      {
        key: "tokens", label: "Tokens", numeric: true,
        value: function (s) { return tokens(data, s); },
        cell: function (s) { return F.compact(tokens(data, s)); },
        title: function (s) { return F.integer(tokens(data, s)); }
      },
      {
        key: "failed", label: "Failed", numeric: true,
        value: function (s) { return s.failures.length; },
        cell: function (s) { return failureFigure(s.failures.length); },
        title: function (s) { return F.count(s.failures.length, "failed call", "failed calls"); }
      }
    ];
  }

  function message(text, button, run) {
    var node = S.el("div", "t-empty");
    node.appendChild(S.el("p", "t-empty__text", text));
    if (button) {
      var action = S.attrs(S.el("button", "t-button", button), { type: "button" });
      action.addEventListener("click", run);
      node.appendChild(action);
    }
    return node;
  }

  function create(app) {
    var data = app.data;
    var state = app.state;
    var node = S.el("section", "t-page t-page--sessions");
    var heading = S.attrs(S.el("h2", "t-title", "Sessions"), { tabindex: "-1" });
    var body = S.el("div", "t-holder");
    var pager = S.pager("Session pages", function (delta) {
      state.page += delta;
      update(null, "page");
      app.sync();
    });
    var spec = columns(data, app.link);
    S.add(node, heading, body, pager.node);

    function matches(session) {
      if (state.harness !== null && session.harness !== state.harness) {
        return false;
      }
      return !state.search || session.search.indexOf(state.search.toLowerCase()) >= 0;
    }

    function empty(change, text, button, run) {
      state.page = 0;
      pager.node.hidden = true;
      body.replaceChildren(message(text, button, run));
      if (change) {
        S.announce(text);
      }
    }

    function outcome(change, paging, total, pages) {
      var found = F.count(total, "session", "sessions");
      var place = pages > 1 ? "page " + (state.page + 1) + " of " + pages : "";
      if (change === "page") {
        return paging;
      }
      return [change === "sort" ? S.sortPhrase(spec, state.sort) : "", found, place].filter(Boolean).join(", ");
    }

    function update(focus, change) {
      var info = T.data.WINDOWS[state.window];
      var span = data.range(state.window, false);
      if (!data.sessions.length) {
        empty(change, "No sessions were recorded in the last 30 days. Run tellem health to check capture.");
        return;
      }
      if (!data.sessionsIn(span, null).length) {
        var longer = info.longer && T.data.WINDOWS[info.longer];
        empty(change, "No sessions in the " + info.label, longer ? "Show " + longer.label.replace("last ", "") : null, function () {
          app.showWindow(info.longer);
        });
        return;
      }
      var found = data.sessionsIn(span, state.repo).filter(matches);
      if (!found.length) {
        empty(change, "No sessions match these filters", "Clear filters", app.clearFilters);
        return;
      }
      var sorted = S.ordered(found, spec, state.sort);
      var pages = Math.ceil(sorted.length / PAGE_SIZE);
      if (state.page >= pages) {
        state.page = 0;
      }
      var shown = sorted.slice(state.page * PAGE_SIZE, (state.page + 1) * PAGE_SIZE);
      body.replaceChildren(S.table({
        id: "sessions",
        caption: "Sessions with activity in the " + info.label + ". Figures cover each whole session within the last 30 days.",
        columns: spec, rows: shown, sort: state.sort, identity: "label",
        onSort: function (key) {
          state.sort = S.nextSort(state.sort, key, spec);
          state.page = 0;
          update(key, "sort");
          app.sync();
        },
        action: {
          id: function (s) { return s.index; },
          name: function (s) { return "Open " + title(s); },
          run: function (s) {
            app.navigate(sessionRoute(s));
          }
        }
      }));
      pager.node.hidden = pages <= 1;
      var paging = pager.update(state.page, pages, sorted.length, "session", "sessions");
      if (change) {
        S.announce(outcome(change, paging, sorted.length, pages));
      }
      if (focus) {
        var button = body.querySelector("button[data-column=\"" + focus + "\"]");
        if (button) {
          button.focus();
        }
      }
    }

    update();
    return {
      name: "sessions",
      title: "Sessions",
      node: node,
      heading: heading,
      update: function (changed) {
        update(null, changed ? "filter" : null);
      },
      restore: function () {
        var button = state.returnTo === null ? null : body.querySelector("button[data-row=\"" + state.returnTo + "\"]");
        if (!button) {
          return false;
        }
        var target = button.offsetParent ? button : button.closest("tr").querySelector("a.t-session__name");
        target.focus();
        return true;
      }
    };
  }

  var SORT_KEYS = columns(null, null).map(function (column) {
    return column.key;
  });

  T.sessions = { create: create, title: title, failureFigure: failureFigure, SORT_KEYS: SORT_KEYS };
})();
