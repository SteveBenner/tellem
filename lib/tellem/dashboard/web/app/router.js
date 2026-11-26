(function () {
  "use strict";
  var T = window.TELLEM;
  var S = T.shell;
  var DAMAGED = "This dashboard file is damaged or from another version. Run tellem dashboard again.";
  var SESSION_ROUTE = /^#\/session\/([^\/]+)\/(agents|timeline|tools)$/;
  var DIRECTIONS = new Map([["asc", "ascending"], ["desc", "descending"]]);
  var DEFAULT_WINDOW = "24h";
  var DEFAULT_SORT = { key: "started", direction: "descending" };
  var DEFAULT_ORDER = { key: "total", direction: "descending" };
  var DEFAULT_TREND = "total_tokens";
  var DEFAULT_GROUP = "model";
  var PAGE_NUMBER = /^[1-9]\d{0,6}$/;

  function byId(id) {
    return document.getElementById(id);
  }

  function settle() {
    var pending = byId("t-pending");
    if (pending) {
      pending.remove();
    }
    byId("t-main").removeAttribute("aria-busy");
  }

  function fail() {
    byId("t-toolbar").hidden = true;
    byId("t-attention").hidden = true;
    var message = S.el("p", "t-damaged", DAMAGED);
    message.setAttribute("role", "alert");
    byId("t-view").replaceChildren(message);
    settle();
  }

  function split() {
    var hash = window.location.hash;
    var at = hash.indexOf("?");
    return at < 0 ? { path: hash, query: "" } : { path: hash.slice(0, at), query: hash.slice(at + 1) };
  }

  function parse(data, path) {
    var match = SESSION_ROUTE.exec(path);
    if (match && data.routes.has(match[1])) {
      return { page: "session", id: match[1], index: data.routes.get(match[1]), tab: match[2] };
    }
    if (path === "#/spend") {
      return { page: "spend" };
    }
    if (path === "#/health") {
      return { page: "health" };
    }
    return { page: "sessions" };
  }

  function pathOf(route) {
    return route.page === "session" ? "#/session/" + route.id + "/" + route.tab : "#/" + route.page;
  }

  function repositoryKeys(data) {
    var seen = new Map();
    return data.repos.map(function (repo) {
      var times = (seen.get(repo.name) || 0) + 1;
      seen.set(repo.name, times);
      return times > 1 ? repo.name + "~" + times : repo.name;
    });
  }

  function decoded(text) {
    try {
      return decodeURIComponent(text);
    } catch (error) {
      if (error instanceof URIError) {
        return null;
      }
      throw error;
    }
  }

  function fields(query) {
    var found = new Map();
    query.split("&").forEach(function (part) {
      var at = part.indexOf("=");
      var value = at < 0 ? null : decoded(part.slice(at + 1));
      if (value !== null) {
        found.set(part.slice(0, at), value);
      }
    });
    return found;
  }

  function chosen(value, allowed, fallback) {
    return allowed.indexOf(value) < 0 ? fallback : value;
  }

  function sorting(value, keys, fallback) {
    var parts = (value || "").split(".");
    var valid = parts.length === 2 && keys.indexOf(parts[0]) >= 0 && DIRECTIONS.has(parts[1]);
    return valid ? { key: parts[0], direction: DIRECTIONS.get(parts[1]) } : { key: fallback.key, direction: fallback.direction };
  }

  function pageNumber(value) {
    return PAGE_NUMBER.test(value) ? Number(value) - 1 : 0;
  }

  function read(data, repositories, query, owner) {
    var found = fields(query);
    var id = found.get("window");
    var repo = repositories.indexOf(found.get("repo"));
    var harness = found.get("harness");
    var tools = owner === null ? new Map() : found;
    var agents = owner === null ? [] : data.sessions[owner].keys;
    return {
      window: Object.prototype.hasOwnProperty.call(T.data.WINDOWS, id) ? id : DEFAULT_WINDOW,
      repo: repo < 0 ? null : repo,
      harness: data.raw.dict.harnesses.indexOf(harness) < 0 ? null : harness,
      search: (found.get("search") || "").replace(/[\r\n]/g, ""),
      sort: sorting(found.get("sort"), T.sessions.SORT_KEYS, DEFAULT_SORT),
      page: pageNumber(found.get("page")),
      dimension: chosen(found.get("group"), T.spend.DIMENSION_KEYS, DEFAULT_GROUP),
      trend: chosen(found.get("trend"), T.spend.TREND_KEYS, DEFAULT_TREND),
      spendSort: sorting(found.get("order"), T.spend.SORT_KEYS, DEFAULT_ORDER),
      toolAgent: chosen(tools.get("agent"), agents, null),
      toolSort: sorting(tools.get("calls"), T.session.TOOL_SORT_KEYS, T.session.TOOL_ORDER),
      failurePage: pageNumber(tools.get("failures"))
    };
  }

  function write(repositories, state, withTools) {
    var parts = [];
    function put(name, value) {
      parts.push(name + "=" + encodeURIComponent(value.replace(/[\uD800-\uDFFF]/gu, "")));
    }
    function putSort(name, sort, fallback) {
      if (sort.key !== fallback.key || sort.direction !== fallback.direction) {
        put(name, sort.key + "." + (sort.direction === "ascending" ? "asc" : "desc"));
      }
    }
    if (state.window !== DEFAULT_WINDOW) {
      put("window", state.window);
    }
    if (state.repo !== null) {
      put("repo", repositories[state.repo]);
    }
    if (state.harness !== null) {
      put("harness", state.harness);
    }
    if (state.search) {
      put("search", state.search);
    }
    putSort("sort", state.sort, DEFAULT_SORT);
    if (state.page > 0) {
      put("page", String(state.page + 1));
    }
    if (state.dimension !== DEFAULT_GROUP) {
      put("group", state.dimension);
    }
    if (state.trend !== DEFAULT_TREND) {
      put("trend", state.trend);
    }
    putSort("order", state.spendSort, DEFAULT_ORDER);
    if (withTools) {
      if (state.toolAgent !== null) {
        put("agent", state.toolAgent);
      }
      putSort("calls", state.toolSort, T.session.TOOL_ORDER);
      if (state.failurePage > 0) {
        put("failures", String(state.failurePage + 1));
      }
    }
    return parts.length ? "?" + parts.join("&") : "";
  }

  function start(data) {
    var repositories = repositoryKeys(data);
    var opening = parse(data, split().path);
    var owner = opening.page === "session" ? opening.index : null;
    var state = read(data, repositories, split().query, owner);
    state.toolSession = owner;
    state.returnTo = null;
    state.trendData = false;
    var view = null;
    var toolbar = null;
    var app = { data: data, state: state };

    app.href = function (path) {
      var route = parse(data, path);
      return path + write(repositories, state, route.page !== "session" || route.index === state.toolSession);
    };
    app.link = function (node, path) {
      node.setAttribute("data-route", path);
      node.setAttribute("href", app.href(path));
      return node;
    };
    app.replace = function (path) {
      var next = app.href(path);
      if (window.location.hash !== next) {
        history.replaceState(null, "", next);
      }
    };
    app.sync = function () {
      Array.prototype.forEach.call(document.querySelectorAll("a[data-route]"), function (link) {
        app.link(link, link.getAttribute("data-route"));
      });
      app.replace(pathOf(parse(data, split().path)));
    };

    function frame() {
      S.readouts(data, state);
      S.attention(data, state, app.link);
    }

    function refresh() {
      frame();
      view.update(true);
      app.sync();
    }

    function apply(query) {
      var next = read(data, repositories, query, state.toolSession);
      var before = write(repositories, state, true);
      Object.keys(next).forEach(function (name) {
        state[name] = next[name];
      });
      return write(repositories, state, true) !== before;
    }

    function open(route) {
      if (route.page === "session") {
        return T.session.create(app, data.sessions[route.index], route.tab);
      }
      return T[route.page].create(app);
    }

    function navigation(page) {
      var current = page === "session" ? "sessions" : page;
      Array.prototype.forEach.call(document.querySelectorAll("[data-page]"), function (link) {
        if (link.getAttribute("data-page") === current) {
          link.setAttribute("aria-current", "page");
        } else {
          link.removeAttribute("aria-current");
        }
      });
    }

    function show(moved) {
      var address = split();
      var route = parse(data, address.path);
      if (route.page === "session") {
        state.returnTo = route.index;
        state.toolSession = route.index;
      }
      var changed = apply(address.query);
      if (changed) {
        toolbar.sync();
        frame();
      }
      if (view && route.page === view.name && (route.page !== "session" || route.index === view.session)) {
        if (route.page === "session") {
          view.update();
          view.tab(route.tab);
        } else if (changed) {
          view.update();
        }
        app.sync();
        return;
      }
      var from = view && view.name;
      S.announce("");
      view = open(route);
      toolbar.page(route.page);
      navigation(route.page);
      byId("t-view").replaceChildren(view.node);
      app.sync();
      document.title = view.title + " - tellem";
      if (moved) {
        window.scrollTo(0, 0);
        if (!(from === "session" && route.page === "sessions" && view.restore())) {
          view.heading.focus();
        }
      }
    }

    app.navigate = function (path) {
      window.location.hash = app.href(path);
    };
    app.showWindow = function (id) {
      state.window = id;
      state.page = 0;
      toolbar.setWindow(id);
      refresh();
      view.heading.focus();
    };
    app.clearFilters = function () {
      state.repo = null;
      state.harness = null;
      state.search = "";
      state.page = 0;
      toolbar.clear();
      refresh();
      view.heading.focus();
    };

    toolbar = S.toolbar(data, state, function () {
      state.page = 0;
      refresh();
    });
    S.footer(data);
    Array.prototype.forEach.call(document.querySelectorAll("[data-page]"), function (link) {
      app.link(link, "#/" + link.getAttribute("data-page"));
    });
    frame();
    byId("t-toolbar").hidden = false;
    byId("t-attention").hidden = false;
    show(false);
    settle();
    window.addEventListener("hashchange", function () {
      show(true);
    });
  }

  function boot() {
    try {
      start(T.data.load(byId("tellem-data").textContent));
    } catch (error) {
      fail();
    }
  }

  S.themeToggle();
  byId("t-skip").addEventListener("click", function (event) {
    event.preventDefault();
    byId("t-main").focus();
  });
  window.requestAnimationFrame(function () {
    window.setTimeout(boot, 0);
  });
})();
