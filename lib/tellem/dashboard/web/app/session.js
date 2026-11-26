(function () {
  "use strict";
  var T = window.TELLEM;
  var F = T.format;
  var S = T.shell;
  var FAILURE_PAGE = 100;
  var TABS = [
    { key: "agents", label: "Agents" },
    { key: "timeline", label: "Timeline" },
    { key: "tools", label: "Tool calls" }
  ];
  var TOOL_SORT_KEYS = ["tool", "calls", "failed", "time"];
  var TOOL_ORDER = { key: "calls", direction: "descending" };

  function known(value) {
    return value !== null && value !== undefined;
  }

  function term(label, value, title, cls) {
    var item = S.el("div", cls);
    var detail = S.el("dd", null, value);
    detail.title = title || value;
    S.add(item, S.el("dt", null, label), detail);
    return item;
  }

  function toolTotals(data, session, agent) {
    var byTool = new Map();
    var order = [];
    session.calls.forEach(function (call) {
      if (agent !== null && call[0] !== agent) {
        return;
      }
      var name = data.word("tools", call[1]) || F.UNKNOWN;
      var entry = byTool.get(name);
      if (!entry) {
        entry = { tool: name, calls: 0, failed: 0, ms: 0, timed: 0 };
        byTool.set(name, entry);
        order.push(entry);
      }
      entry.calls += call[2];
      entry.failed += call[3];
      if (call[5] > 0) {
        entry.ms += call[4];
        entry.timed += call[5];
      }
    });
    return order;
  }

  function seconds(entry) {
    return entry.timed > 0 ? entry.ms / 1000 : null;
  }

  function timeTitle(entry) {
    return entry.timed > 0
      ? F.integer(entry.ms) + " ms over " + F.integer(entry.timed) + " of " + F.count(entry.calls, "call", "calls")
      : F.NOT_RECORDED;
  }

  function toolTable(data, session, agent, caption, sorting) {
    var rows = toolTotals(data, session, agent);
    if (!rows.length) {
      return S.el("p", "t-quiet", "No tool calls recorded");
    }
    function number(key, label) {
      return {
        key: key, label: label, numeric: true,
        value: function (r) { return r[key]; },
        cell: function (r) { return F.integer(r[key]); },
        title: function (r) { return F.integer(r[key]); }
      };
    }
    var columns = [
      {
        key: "tool", label: "Tool",
        value: function (r) { return r.tool; },
        cell: function (r) { return r.tool; },
        title: function (r) { return r.tool; }
      },
      number("calls", "Calls"),
      number("failed", "Failed"),
      {
        key: "time", label: "Time", numeric: true,
        value: seconds,
        cell: function (r) { return F.duration(seconds(r)); },
        title: timeTitle
      }
    ];
    var footer = null;
    if (sorting) {
      var sum = rows.reduce(function (out, r) {
        out.calls += r.calls;
        out.failed += r.failed;
        out.ms += r.ms;
        out.timed += r.timed;
        return out;
      }, { calls: 0, failed: 0, ms: 0, timed: 0 });
      footer = {
        tool: { text: "Total" },
        calls: { text: F.integer(sum.calls) },
        failed: { text: F.integer(sum.failed) },
        time: { text: F.duration(seconds(sum)), title: timeTitle(sum) }
      };
    }
    var spec = { id: "tools", caption: caption, columns: columns, rows: rows, identity: "tool", footer: footer };
    if (sorting) {
      spec.sort = sorting.sort;
      spec.remember = sorting.remember;
      spec.noun = ["tool", "tools"];
      return S.sortableTable(spec);
    }
    spec.rows = S.ordered(rows, columns, TOOL_ORDER);
    return S.table(spec);
  }

  function create(app, session, first) {
    var data = app.data;
    var state = app.state;
    var node = S.el("section", "t-page t-page--session");
    var selected = 0;
    var panels = {};
    var built = {};
    var current = null;
    var tree = null;
    var detail = null;
    var expanded = {};
    var failures = [];
    var refreshTools = null;
    session.agents.forEach(function () {
      failures.push(0);
    });
    session.failures.forEach(function (failure) {
      failures[failure[1]] += 1;
    });
    session.agents.forEach(function (agent, index) {
      if (known(agent.parent)) {
        expanded[agent.parent] = true;
      }
      if (agent.key === "main" && session.agents[selected].key !== "main") {
        selected = index;
      }
    });

    var title = T.sessions.title(session);
    var crumbs = S.attrs(S.el("nav", "t-crumbs"), { "aria-label": "Breadcrumb" });
    crumbs.appendChild(app.link(S.el("a", "t-link", "Sessions"), "#/sessions"));
    var heading = S.attrs(S.el("h2", "t-title", title), { tabindex: "-1" });

    var meta = S.el("p", "t-meta");
    function fact(text, hint, cls) {
      var item = S.el("span", cls || "t-meta__item", text);
      item.title = hint || text;
      meta.appendChild(item);
    }
    fact(session.repoName, "Repository " + session.repoName);
    fact(session.harness || F.UNKNOWN, "Harness " + (session.harness || F.UNKNOWN));
    fact("Started " + F.dateTime(session.started), "Started " + F.fullTime(session.started));
    if (session.open) {
      meta.appendChild(S.badge("running"));
    } else {
      fact("Ended " + F.dateTime(session.ended), "Ended " + F.fullTime(session.ended));
    }
    if (!data.share && session.home) {
      fact(session.home, "Home " + session.home, "t-meta__item t-meta__item--path");
    }

    var tokens = data.counter(session.total, "total_tokens");
    var figures = S.attrs(S.el("dl", "t-line"), { "aria-label": "Session figures" });
    S.add(figures,
      term("Agents", F.integer(session.agents.length)),
      term("Active time", F.duration(session.active), session.active === null ? F.NOT_RECORDED : "Time with at least one agent active: " + F.exactDuration(session.active)),
      term("Tokens", F.compact(tokens), F.integer(tokens)),
      term("Failed calls", F.integer(session.failures.length))
    );

    var tabs = S.rui("composite.navigation.tabs", { tabs: TABS, selected: first });
    S.add(node, crumbs, heading, meta, figures, tabs);
    TABS.forEach(function (tab) {
      panels[tab.key] = tabs.querySelector("[data-rui-slot=\"" + tab.key + "\"]");
    });
    var buttons = tabs.querySelectorAll("[role=tab]");
    tabs.querySelector("[role=tablist]").setAttribute("aria-label", "Session views");

    function sync() {
      TABS.forEach(function (tab, index) {
        if (buttons[index].getAttribute("aria-selected") === "true" && tab.key !== current) {
          show(tab.key);
          app.replace("#/session/" + session.route + "/" + tab.key);
        }
      });
    }

    TABS.forEach(function (tab, index) {
      buttons[index].title = tab.label;
      buttons[index].addEventListener("click", sync);
      buttons[index].addEventListener("keydown", sync);
    });

    function label(index) {
      var name = T.timeline.agentName(data, session, index);
      return name.full + (failures[index] ? ", " + F.integer(failures[index]) + " failed" : "");
    }

    function decorate() {
      Array.prototype.forEach.call(tree.querySelectorAll("[role=treeitem]"), function (item) {
        var index = Number(item.getAttribute("data-node-id"));
        var name = T.timeline.agentName(data, session, index);
        var row = item.firstElementChild;
        var marker = row.firstElementChild;
        marker.replaceChildren();
        if (item.hasAttribute("aria-expanded")) {
          marker.appendChild(S.icon(item.getAttribute("aria-expanded") === "true" ? "opened" : "closed"));
        }
        var text = S.el("span", "t-node");
        text.appendChild(S.el("span", "t-node__type", name.type));
        if (name.key) {
          text.appendChild(S.el("span", "t-node__key", name.key));
        }
        if (failures[index]) {
          text.appendChild(S.el("span", "t-node__failed", F.integer(failures[index]) + " failed"));
        }
        row.replaceChildren(marker, text);
        row.title = label(index);
      });
    }

    function plant() {
      var nodes = session.agents.map(function (agent, index) {
        var entry = { id: String(index), label: label(index) };
        if (known(agent.parent)) {
          entry.parentId = String(agent.parent);
        }
        return entry;
      });
      var next = S.rui("composite.navigation.tree-explorer", {
        label: "Agents", nodes: nodes, selected: String(selected),
        expanded: Object.keys(expanded).filter(function (key) { return expanded[key]; })
      });
      next.classList.add("t-tree");
      next.setAttribute("data-density", "cockpit");
      next.addEventListener("rui:tree-explorer:activate", function (event) {
        selected = Number(event.detail.id);
        describe(true);
      });
      next.addEventListener("rui:tree-explorer:expand", function (event) {
        expanded[event.detail.id] = event.detail.expanded;
        decorate();
      });
      if (tree) {
        tree.replaceWith(next);
      }
      tree = next;
      decorate();
      return next;
    }

    function describe(spoken) {
      if (!session.agents.length) {
        return;
      }
      var agent = session.agents[selected];
      var name = T.timeline.agentName(data, session, selected);
      var total = session.byAgent[selected];
      var calls = toolTotals(data, session, selected);
      var subtitle = S.el("h3", "t-subtitle", name.full);
      subtitle.title = agent.key;
      var grid = S.el("dl", "t-grid");
      function counted(caption, value) {
        var text = F.integer(known(value) ? value : null);
        grid.appendChild(term(caption, text));
      }
      function timed(caption, value) {
        grid.appendChild(term(caption, F.duration(value), F.exactDuration(value)));
      }
      grid.appendChild(term("Type", name.type));
      grid.appendChild(term("Model", data.word("models", agent.model) || F.UNKNOWN));
      grid.appendChild(term("Effort", data.word("efforts", agent.effort) || F.UNKNOWN));
      grid.appendChild(term("Isolation", agent.isolation || F.NOT_RECORDED));
      grid.appendChild(term("Started", F.dateTime(agent.started), F.fullTime(agent.started)));
      grid.appendChild(term("Ended", agent.open ? "running" : F.dateTime(agent.ended), agent.open ? "running" : F.fullTime(agent.ended)));
      timed("Wall time", agent.wall);
      timed("Active time", agent.active);
      timed("Waiting time", agent.waiting);
      counted("Requests", total ? total.requests : null);
      [
        ["Input", "input_tokens"], ["Output", "output_tokens"], ["Cache read", "cache_read_input_tokens"],
        ["Cache write", "cache_creation_input_tokens"], ["Reasoning", "reasoning_tokens"], ["Total tokens", "total_tokens"]
      ].forEach(function (pair) {
        counted(pair[0], total ? data.counter(total, pair[1]) : null);
      });
      var made = calls.length ? calls.reduce(function (sum, r) { return sum + r.calls; }, 0) : null;
      counted("Tool calls", made);
      counted("Failed calls", calls.length || failures[selected] ? failures[selected] : null);
      detail.replaceChildren(subtitle, grid, toolTable(data, session, selected, "Tools used by this agent", null));
      if (spoken) {
        S.announce([name.full, F.count(calls.length, "tool", "tools"), F.count(failures[selected] || 0, "failed call", "failed calls")].join(", "));
      }
    }

    function agentsPanel() {
      var layout = S.el("div", "t-agents");
      if (!session.agents.length) {
        layout.appendChild(S.el("p", "t-quiet", "No agents recorded"));
        return layout;
      }
      detail = S.attrs(S.el("div", "t-agents__detail"), { "data-density": "cockpit" });
      var side = S.el("div", "t-agents__tree");
      side.appendChild(plant());
      S.add(layout, side, detail);
      describe();
      new ResizeObserver(function () {
        var fits = detail.getBoundingClientRect().height <= window.innerHeight;
        detail.classList.toggle("t-agents__detail--pinned", fits);
      }).observe(detail);
      return layout;
    }

    function toolsPanel() {
      var panel = S.el("div", "t-stack");
      var options = [{ value: "all", label: "All agents" }].concat(session.agents.map(function (agent, index) {
        return { value: String(index), label: T.timeline.agentName(data, session, index).full };
      }));
      var agent = null;
      var drawn = "";
      var summary = S.el("div", "t-holder");
      var listing = S.el("div", "t-holder");
      var pager = S.pager("Failed call pages", function (delta) {
        state.failurePage += delta;
        S.announce(list().paging);
        app.sync();
      });
      var select = S.selectField("Agent", "agent", options, "all", function (value) {
        agent = value === "all" ? null : Number(value);
        state.toolAgent = agent === null ? null : session.agents[agent].key;
        state.failurePage = 0;
        var shown = draw();
        var parts = [
          options[agent === null ? 0 : agent + 1].label,
          F.count(shown.tools, "tool", "tools"),
          F.count(shown.failed, "failed call", "failed calls")
        ];
        if (shown.pages > 1) {
          parts.push("page " + (state.failurePage + 1) + " of " + shown.pages);
        }
        S.announce(parts.join(", "));
        app.sync();
      });

      function stamp() {
        return [state.toolAgent, state.toolSort.key, state.toolSort.direction, state.failurePage].join("|");
      }

      function list() {
        var found = session.failures.filter(function (failure) {
          return agent === null || failure[1] === agent;
        });
        var pages = Math.max(1, Math.ceil(found.length / FAILURE_PAGE));
        var page = Math.max(0, Math.min(state.failurePage, pages - 1));
        state.failurePage = page;
        drawn = stamp();
        function name(r) {
          return T.timeline.agentName(data, session, r[1]).full;
        }
        function tool(r) {
          return data.word("tools", r[2]) || F.UNKNOWN;
        }
        function took(r) {
          return known(r[3]) ? r[3] / 1000 : null;
        }
        listing.replaceChildren(S.table({
          id: "failures", caption: "Failed calls", empty: "No failed calls", identity: "time",
          rows: found.slice(page * FAILURE_PAGE, (page + 1) * FAILURE_PAGE),
          columns: [
            { key: "time", label: "Time", cell: function (r) { return F.dateTime(r[0]); }, title: function (r) { return F.fullTime(r[0]); } },
            { key: "agent", label: "Agent", cell: name, title: name },
            { key: "tool", label: "Tool", cell: tool, title: tool },
            {
              key: "duration", label: "Duration", numeric: true,
              cell: function (r) { return F.duration(took(r)); },
              title: function (r) { return known(r[3]) ? F.integer(r[3]) + " ms" : F.NOT_RECORDED; }
            }
          ]
        }));
        pager.node.hidden = found.length <= FAILURE_PAGE;
        var paging = pager.update(page, pages, found.length, "failed call", "failed calls");
        return { paging: paging, pages: pages, failed: found.length };
      }

      function draw() {
        summary.replaceChildren(toolTable(data, session, agent, "Calls by tool", {
          sort: state.toolSort,
          remember: function (sort) {
            state.toolSort = sort;
            drawn = stamp();
            app.sync();
          }
        }));
        var shown = list();
        shown.tools = toolTotals(data, session, agent).length;
        return shown;
      }

      function adopt() {
        var at = session.keys.indexOf(state.toolAgent);
        agent = at < 0 ? null : at;
        select.set(agent === null ? "all" : String(agent));
        draw();
      }

      var controls = S.el("div", "t-controls");
      controls.setAttribute("data-density", "cockpit");
      controls.appendChild(select.node);
      S.add(panel, controls, summary, listing, pager.node);
      adopt();
      refreshTools = function () {
        if (stamp() !== drawn) {
          adopt();
        }
      };
      return panel;
    }

    function openAgent(index) {
      selected = index;
      var walk = session.agents[index].parent;
      while (known(walk)) {
        expanded[walk] = true;
        walk = session.agents[walk].parent;
      }
      buttons[0].click();
      plant();
      describe();
      var item = tree.querySelector("[data-node-id=\"" + index + "\"]");
      if (item) {
        item.focus();
      }
    }

    function show(key) {
      current = key;
      if (built[key]) {
        return;
      }
      built[key] = true;
      if (key === "agents") {
        panels[key].appendChild(agentsPanel());
      } else if (key === "timeline") {
        panels[key].appendChild(T.timeline.create(data, session, { open: openAgent }));
      } else {
        panels[key].appendChild(toolsPanel());
      }
    }

    show(first);

    return {
      name: "session",
      title: title,
      node: node,
      heading: heading,
      session: session.index,
      update: function () {
        if (refreshTools) {
          refreshTools();
        }
      },
      restore: function () {
        return false;
      },
      tab: function (key) {
        var index = TABS.map(function (tab) { return tab.key; }).indexOf(key);
        if (index >= 0 && key !== current) {
          buttons[index].click();
        }
      }
    };
  }

  T.session = { create: create, TOOL_SORT_KEYS: TOOL_SORT_KEYS, TOOL_ORDER: TOOL_ORDER };
})();
