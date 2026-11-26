(function () {
  "use strict";
  var T = window.TELLEM;
  var F = T.format;
  var S = T.shell;
  var IDLE_BREAK = 1800;
  var ROW_STEP = 200;
  var DEPTH_LIMIT = 5;
  var BREAK_PIXELS = 24;
  var BREAK_SHARE = 0.4;
  var NARROW_BREAK = 16;
  var BREAK_LIMIT = 0.7;
  var TOO_NARROW = "The chart needs more width to label this session's idle breaks";
  var MARK_SPACING = 8;
  var MARK_REACH = 12;
  var IDLE_CHROME = 25;
  var AXIS_STEP = 4;
  var STEPS = [1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600, 7200, 10800, 21600, 43200, 86400, 172800, 604800];
  var MOST_TICKS = 8;
  var FEWEST_TICKS = 4;

  function known(value) {
    return value !== null && value !== undefined;
  }

  function agentName(data, session, index) {
    var agent = session.agents[index];
    var type = agent.key === "main" ? "main" : data.word("agent_types", agent.type) || F.UNKNOWN;
    var short = F.shortKey(agent.key, session.keys);
    return { type: type, key: agent.key === "main" ? "" : short, full: agent.key === "main" ? "main" : type + " " + short };
  }

  function model(data, session) {
    var failures = session.agents.map(function () { return []; });
    session.failures.forEach(function (failure) {
      failures[failure[1]].push(failure);
    });
    var instants = [];
    var busy = [];
    session.agents.forEach(function (agent) {
      [agent.started, agent.ended].forEach(function (at) {
        if (known(at)) {
          instants.push(at);
        }
      });
      agent.spans.forEach(function (span) {
        busy.push(span);
        instants.push(span[0], span[1]);
      });
    });
    session.failures.forEach(function (failure) {
      busy.push([failure[0], failure[0]]);
      instants.push(failure[0]);
    });
    var first = instants.length ? instants.reduce(function (a, b) { return Math.min(a, b); }) : session.started;
    var last = instants.length ? instants.reduce(function (a, b) { return Math.max(a, b); }) : session.started;
    var merged = data.union(busy);
    var breaks = [];
    if (merged.length) {
      var cursor = first;
      merged.concat([[last, last]]).forEach(function (pair) {
        if (pair[0] - cursor >= IDLE_BREAK) {
          breaks.push([cursor, pair[0]]);
        }
        cursor = Math.max(cursor, pair[1]);
      });
    }
    var linear = last - first - breaks.reduce(function (sum, gap) { return sum + gap[1] - gap[0]; }, 0);

    function at(time) {
      var run = 0;
      var passed = 0;
      var from = first;
      for (var i = 0; i < breaks.length; i += 1) {
        var gap = breaks[i];
        if (time <= gap[0]) {
          break;
        }
        run += gap[0] - from;
        if (time < gap[1]) {
          return { share: linear > 0 ? run / linear : 0, breaks: passed + (time - gap[0]) / (gap[1] - gap[0]) };
        }
        passed += 1;
        from = gap[1];
      }
      run += Math.max(0, time - from);
      return { share: linear > 0 ? Math.min(1, run / linear) : 0, breaks: passed };
    }

    var children = session.agents.map(function () { return []; });
    var depth = [];
    session.agents.forEach(function (agent, index) {
      if (known(agent.parent)) {
        children[agent.parent].push(index);
        depth[index] = depth[agent.parent] + 1;
      } else {
        depth[index] = 0;
      }
    });
    return { failures: failures, first: first, last: last, breaks: breaks, linear: linear, at: at, children: children, depth: depth };
  }

  function round(value) {
    return Math.round(value * 1000000) / 1000000;
  }

  function left(time, count) {
    var point = time;
    return "calc((100% - " + count + " * var(--tl-b)) * " + round(point.share) + " + var(--tl-b) * " + round(point.breaks) + ")";
  }

  function span(from, to, count) {
    return "calc((100% - " + count + " * var(--tl-b)) * " + round(to.share - from.share) + " + var(--tl-b) * " + round(to.breaks - from.breaks) + ")";
  }

  function lifeEnd(agent, failures) {
    var latest = agent.spans.reduce(function (most, pair) { return Math.max(most, pair[1]); }, agent.started);
    latest = failures.reduce(function (most, failure) { return Math.max(most, failure[0]); }, latest);
    return agent.open || !known(agent.ended) ? latest : Math.max(agent.ended, agent.started);
  }

  function figuresOf(data, session, shape, index) {
    var agent = session.agents[index];
    return {
      name: agentName(data, session, index).full,
      started: F.dateTime(agent.started),
      ended: agent.open ? "running" : F.dateTime(agent.ended),
      active: F.duration(agent.active),
      wall: F.duration(agent.wall),
      failed: shape.failures[index].length
    };
  }

  function create(data, session, hooks) {
    var shape = model(data, session);
    var count = shape.breaks.length;
    var collapsed = {};
    var limit = ROW_STEP;
    var focused = 0;
    var asTable = false;
    var chosen = false;
    var root = S.el("div", "t-timeline");
    root.setAttribute("data-density", "cockpit");
    if (!session.agents.length) {
      root.appendChild(S.el("p", "t-quiet", "No agents recorded"));
      return root;
    }
    var ruler = S.attrs(S.el("div", "t-timeline__ruler"), { "aria-hidden": "true" });
    var bar = S.el("div", "t-timeline__bar");
    var toggle = S.attrs(S.el("button", "t-button t-button--toggle", "Show as table"), { type: "button", "aria-pressed": "false" });
    var reason = S.el("p", "t-quiet t-timeline__reason", TOO_NARROW);
    reason.hidden = true;
    S.add(bar, toggle, reason);
    var chart = S.attrs(S.el("div", "t-tl" + (count ? " t-tl--broken" : "")), { role: "treegrid", "aria-label": "Agent timeline", "data-density": "cockpit" });
    chart.style.setProperty("--tl-n", String(Math.max(1, count)));
    var axis = S.attrs(S.el("div", "t-tl__axis"), { "aria-hidden": "true" });
    var corner = S.el("div", "t-tl__corner", "Agent");
    var scale = S.el("div", "t-tl__scale");
    var ticks = S.el("div", "t-tl__ticks");
    var idle = shape.breaks.map(function (gap, index) {
      var length = F.duration(gap[1] - gap[0]);
      var label = S.el("span", "t-tl__idle");
      label.style.left = left({ share: shape.at(gap[0]).share, breaks: index }, count);
      label.title = "idle " + length;
      var text = S.el("span", "t-tl__idle-text", length);
      label.appendChild(text);
      scale.appendChild(label);
      return text;
    });
    scale.appendChild(ticks);
    S.add(axis, corner, scale);
    var body = S.attrs(S.el("div", "t-tl__rows"), { role: "rowgroup" });
    S.add(chart, axis, body);
    var table = S.el("div", "t-holder");
    table.hidden = true;
    var more = S.attrs(S.el("button", "t-button t-button--more", "Show 200 more"), { type: "button" });
    S.add(root, ruler, bar, chart, table, more);

    function visible() {
      var hidden = {};
      var out = [];
      session.agents.forEach(function (agent, index) {
        var parent = agent.parent;
        if (known(parent) && (hidden[parent] || collapsed[parent])) {
          hidden[index] = true;
          return;
        }
        out.push(index);
      });
      return out;
    }

    function marks(index, track) {
      var agent = session.agents[index];
      shape.breaks.forEach(function (gap, at) {
        var block = S.el("span", "t-tl__break");
        block.style.left = left({ share: shape.at(gap[0]).share, breaks: at }, count);
        block.title = "idle " + F.duration(gap[1] - gap[0]);
        track.appendChild(block);
      });
      if (known(agent.started)) {
        var end = lifeEnd(agent, shape.failures[index]);
        var from = shape.at(agent.started);
        var to = shape.at(end);
        var life = S.el("span", "t-tl__life" + (agent.open ? " t-tl__life--open" : ""));
        life.style.left = "min(" + left(from, count) + ", 100% - 2px)";
        life.style.width = "max(2px, " + span(from, to, count) + ")";
        life.title = "From " + F.dateTime(agent.started) + (agent.open ? ", running" : " to " + F.dateTime(end));
        track.appendChild(life);
        agent.spans.forEach(function (pair) {
          var begin = shape.at(pair[0]);
          var stop = shape.at(pair[1]);
          var active = S.el("span", "t-tl__active");
          active.style.left = "min(" + left(begin, count) + ", 100% - 2px)";
          active.style.width = "max(2px, " + span(begin, stop, count) + ")";
          active.title = "Active from " + F.dateTime(pair[0]) + " to " + F.dateTime(pair[1]);
          track.appendChild(active);
        });
      }
    }

    function clusters(failures, width) {
      var block = breakWidth(width);
      var free = width - count * block;
      var out = [];
      failures.slice().sort(function (a, b) { return a[0] - b[0]; }).forEach(function (failure) {
        var point = shape.at(failure[0]);
        var x = Math.max(MARK_REACH, Math.min(width - MARK_REACH, free * point.share + block * point.breaks));
        var open = out[out.length - 1];
        if (open && x - open.x < MARK_SPACING) {
          open.held.push(failure);
        } else {
          out.push({ x: x, held: [failure] });
        }
      });
      return out;
    }

    function markTitle(held) {
      if (held.length === 1) {
        return "Failed " + (data.word("tools", held[0][2]) || F.UNKNOWN) + " at " + F.fullTime(held[0][0]);
      }
      return F.count(held.length, "failed call", "failed calls") + ", first at " + F.fullTime(held[0][0]) + ", last at " + F.fullTime(held[held.length - 1][0]);
    }

    function pin(width) {
      Array.prototype.forEach.call(body.querySelectorAll(".t-tl__row"), function (line) {
        var track = line.querySelector(".t-tl__track");
        Array.prototype.forEach.call(track.querySelectorAll(".t-tl__fail"), function (old) {
          old.remove();
        });
        clusters(shape.failures[Number(line.getAttribute("data-agent"))], width).forEach(function (group) {
          var title = markTitle(group.held);
          var mark = S.attrs(S.el("span", "t-tl__fail"), { role: "img", "aria-label": title });
          mark.style.left = "clamp(0px, " + left(shape.at(group.held[0][0]), count) + " - 12px, 100% - 24px)";
          mark.title = title;
          mark.appendChild(S.el("span", "t-tl__diamond"));
          track.appendChild(mark);
        });
      });
    }

    function row(index) {
      var agent = session.agents[index];
      var name = agentName(data, session, index);
      var facts = figuresOf(data, session, shape, index);
      var branch = shape.children[index].length > 0;
      var node = S.attrs(S.el("div", "t-tl__row"), {
        role: "row", "aria-level": shape.depth[index] + 1, "data-agent": index,
        "aria-expanded": branch ? String(!collapsed[index]) : null
      });
      var spoken = "Agent " + name.full + ", started " + facts.started + ", ended " + facts.ended + ", active " + facts.active +
        ", wall time " + facts.wall + ", " + F.count(facts.failed, "failed call", "failed calls") + (agent.open ? ", running" : "");
      node.setAttribute("aria-label", spoken);
      node.tabIndex = index === focused ? 0 : -1;
      var head = S.attrs(S.el("div", "t-tl__head"), { role: "rowheader" });
      var indent = S.el("span", "t-tl__indent");
      indent.style.setProperty("--tl-depth", String(Math.min(shape.depth[index], DEPTH_LIMIT)));
      head.appendChild(indent);
      if (branch) {
        var button = S.attrs(S.el("button", "t-tl__toggle"), {
          type: "button", tabindex: "-1",
          "aria-label": (collapsed[index] ? "Expand" : "Collapse") + " subagents of " + name.full
        });
        button.appendChild(S.icon(collapsed[index] ? "closed" : "opened"));
        button.addEventListener("click", function (event) {
          event.stopPropagation();
          collapse(index, !collapsed[index]);
        });
        head.appendChild(button);
      } else {
        head.appendChild(S.el("span", "t-tl__spacer"));
      }
      var text = S.el("span", "t-tl__name");
      text.appendChild(S.el("span", "t-tl__type", name.type));
      if (name.key) {
        text.appendChild(document.createTextNode(" "));
        text.appendChild(S.el("span", "t-tl__key", name.key));
      }
      text.title = spoken;
      head.appendChild(text);
      if (agent.open) {
        head.appendChild(S.attrs(S.el("span", "t-tl__state", "running"), { title: "running" }));
      }
      head.title = spoken;
      var track = S.attrs(S.el("div", "t-tl__track"), { role: "gridcell" });
      marks(index, track);
      S.add(node, head, track);
      node.addEventListener("click", function () {
        hooks.open(index);
      });
      node.addEventListener("focus", function () {
        move(index, false);
      });
      node.addEventListener("keydown", function (event) {
        keys(event, index);
      });
      return node;
    }

    function find(index) {
      return body.querySelector("[data-agent=\"" + index + "\"]");
    }

    function move(index, focus) {
      var previous = find(focused);
      if (previous) {
        previous.tabIndex = -1;
      }
      focused = index;
      var next = find(index);
      if (next) {
        next.tabIndex = 0;
        if (focus) {
          next.focus();
        }
      }
    }

    function collapse(index, closed) {
      collapsed[index] = closed;
      focused = index;
      draw();
      move(index, true);
    }

    function keys(event, index) {
      if (event.altKey || event.ctrlKey || event.metaKey || event.target !== event.currentTarget) {
        return;
      }
      var order = visible().slice(0, limit);
      var at = order.indexOf(index);
      var branch = shape.children[index].length > 0;
      var target = null;
      if (event.key === "ArrowDown") {
        target = order[at + 1];
      } else if (event.key === "ArrowUp") {
        target = order[at - 1];
      } else if (event.key === "Home") {
        target = order[0];
      } else if (event.key === "End") {
        target = order[order.length - 1];
      } else if (event.key === "ArrowLeft") {
        if (branch && !collapsed[index]) {
          event.preventDefault();
          collapse(index, true);
          return;
        }
        target = session.agents[index].parent;
      } else if (event.key === "ArrowRight") {
        if (branch && collapsed[index]) {
          event.preventDefault();
          collapse(index, false);
          return;
        }
        target = branch ? shape.children[index][0] : null;
      } else if (event.key === "Enter") {
        event.preventDefault();
        hooks.open(index);
        return;
      } else {
        return;
      }
      event.preventDefault();
      if (known(target) && order.indexOf(target) >= 0) {
        move(target, true);
      }
    }

    function tableOf(shown) {
      var rows = shown.map(function (index) { return figuresOf(data, session, shape, index); });
      function column(key, label, numeric) {
        return {
          key: key, label: label, numeric: numeric,
          cell: function (r) { return key === "failed" ? T.sessions.failureFigure(r.failed) : r[key]; },
          title: function (r) { return String(r[key]); }
        };
      }
      return S.table({
        id: "agents", caption: "Agent timeline as a table", identity: "name", rows: rows,
        columns: [
          column("name", "Agent"), column("started", "Started"), column("ended", "Ended"),
          column("active", "Active", true), column("wall", "Wall", true), column("failed", "Failed", true)
        ]
      });
    }

    function draw() {
      var all = visible();
      var shown = all.slice(0, limit);
      if (shown.indexOf(focused) < 0) {
        focused = shown[0];
      }
      chart.hidden = asTable;
      table.hidden = !asTable;
      if (asTable) {
        body.replaceChildren();
        table.replaceChildren(tableOf(shown));
      } else {
        table.replaceChildren();
        var fragment = document.createDocumentFragment();
        shown.forEach(function (index) {
          fragment.appendChild(row(index));
        });
        body.replaceChildren(fragment);
      }
      more.hidden = all.length <= limit;
      more.title = F.count(all.length - shown.length, "row", "rows") + " not shown";
      layout();
    }

    function aligned(from, step) {
      var offset = new Date(from * 1000).getTimezoneOffset() * 60;
      return Math.ceil((from - offset) / step) * step + offset;
    }

    function segments() {
      var out = [];
      var from = shape.first;
      shape.breaks.forEach(function (gap) {
        out.push([from, gap[0]]);
        from = gap[1];
      });
      out.push([from, shape.last]);
      return out.filter(function (pair) { return pair[1] > pair[0]; });
    }

    function breakWidth(width) {
      var shared = Math.min(BREAK_PIXELS, width * BREAK_SHARE / Math.max(1, count));
      return shared < NARROW_BREAK && count * NARROW_BREAK <= width * BREAK_LIMIT ? NARROW_BREAK : shared;
    }

    function labelSize(text) {
      return text.length * 7 + 9;
    }

    function manyDays() {
      return F.monthDay(shape.first) !== F.monthDay(shape.last);
    }

    function candidates(step, width) {
      var block = breakWidth(width);
      var free = width - count * block;
      var dated = manyDays();
      var picked = [];
      var edge = -8;
      var day = null;
      segments().forEach(function (pair) {
        for (var time = aligned(pair[0], step); time <= pair[1]; time += step) {
          var point = shape.at(time);
          var x = free * point.share + block * point.breaks;
          if (x < edge + 8) {
            continue;
          }
          var text = step < 60 ? F.fullTime(time).slice(-8) : F.clock(time);
          if (dated && F.monthDay(time) !== day) {
            text = F.monthDay(time) + " " + text;
          }
          var size = labelSize(text);
          if (x + size > width) {
            continue;
          }
          picked.push({ x: x, text: text, size: size, time: time });
          edge = x + size;
          day = F.monthDay(time);
        }
      });
      return picked;
    }

    function dateLabels(kept, width) {
      var dated = manyDays();
      var day = null;
      var edge = 0;
      return kept.reduce(function (out, tick) {
        var text = tick.text.replace(/^\d\d-\d\d /, "");
        var today = F.monthDay(tick.time);
        if (dated && today !== day) {
          text = today + " " + text;
        }
        var size = labelSize(text);
        if (tick.x >= edge && tick.x + size <= width) {
          out.push({ x: tick.x, text: text });
          edge = tick.x + size;
          day = today;
        }
        return out;
      }, []);
    }

    function fitIdle() {
      if (!idle.length) {
        return;
      }
      var longest = idle.reduce(function (most, label) {
        return Math.max(most, label.offsetHeight);
      }, 0);
      chart.style.setProperty("--tl-axis", Math.ceil((longest + IDLE_CHROME) / AXIS_STEP) * AXIS_STEP + "px");
    }

    function startTick() {
      var text = shape.linear < 60 ? F.fullTime(shape.first).slice(-8) : F.clock(shape.first);
      return { x: 0, text: text, time: shape.first };
    }

    function layout() {
      var width = scale.clientWidth;
      if (!width) {
        return;
      }
      chart.style.setProperty("--tl-b", breakWidth(width) + "px");
      fitIdle();
      var best = [];
      for (var i = STEPS.length - 1; i >= 0; i -= 1) {
        if (shape.linear / STEPS[i] > 600) {
          break;
        }
        var found = candidates(STEPS[i], width);
        if (found.length > best.length) {
          best = found;
        }
        if (found.length >= FEWEST_TICKS) {
          break;
        }
      }
      var every = Math.ceil(best.length / MOST_TICKS);
      var kept = best.filter(function (tick, index) { return index % every === 0; });
      var labels = dateLabels(kept, width);
      if (!labels.length) {
        labels = dateLabels([startTick()], width);
      }
      ticks.replaceChildren();
      labels.forEach(function (tick) {
        var node = S.el("span", "t-tl__tick", tick.text);
        node.style.left = tick.x + "px";
        ticks.appendChild(node);
      });
      pin(width);
    }

    function present(next) {
      asTable = next;
      toggle.setAttribute("aria-pressed", String(asTable));
      draw();
    }

    function tooNarrow() {
      if (!count || !root.clientWidth) {
        return false;
      }
      var name = parseFloat(getComputedStyle(chart).getPropertyValue("--tl-name"));
      return breakWidth(root.clientWidth - name - 2) < NARROW_BREAK;
    }

    function settle() {
      if (!root.clientWidth) {
        return;
      }
      var narrow = tooNarrow();
      var next = narrow || chosen;
      toggle.setAttribute("aria-disabled", String(narrow));
      toggle.title = narrow ? TOO_NARROW : "";
      reason.hidden = !narrow;
      if (next !== asTable) {
        present(next);
      }
    }

    toggle.addEventListener("click", function () {
      if (toggle.getAttribute("aria-disabled") === "true") {
        return;
      }
      chosen = !asTable;
      present(chosen);
    });
    more.addEventListener("click", function () {
      var before = visible().slice(0, limit).length;
      limit += ROW_STEP;
      draw();
      var all = visible().length;
      S.announce("Showing " + F.integer(Math.min(limit, all)) + " of " + F.count(all, "agent", "agents"));
      if (!asTable) {
        move(visible()[before], true);
      } else if (more.hidden) {
        table.querySelector(".rui-table__region").focus();
      }
    });
    draw();
    new ResizeObserver(function () {
      settle();
      layout();
    }).observe(ruler);
    return root;
  }

  T.timeline = { create: create, agentName: agentName };
})();
