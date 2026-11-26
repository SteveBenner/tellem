(function () {
  "use strict";
  var T = window.TELLEM;
  var SCHEMA = "tellem.dashboard/v1";
  var HOUR = 3600;
  var WINDOWS = {
    "24h": { id: "24h", hours: 24, label: "last 24 hours", prior: "vs prior 24h", longer: "7d" },
    "7d": { id: "7d", hours: 168, label: "last 7 days", prior: "vs prior 7d", longer: "30d" },
    "30d": { id: "30d", hours: 720, label: "last 30 days", prior: null, longer: null }
  };
  var COUNTERS = ["input_tokens", "output_tokens", "cache_read_input_tokens", "cache_creation_input_tokens", "reasoning_tokens", "total_tokens"];
  var FIRST_COUNTER = 8;

  function demand(condition) {
    if (!condition) {
      throw new Error("shape");
    }
  }

  function check(data) {
    demand(data && typeof data === "object" && data.schema === SCHEMA);
    ["counters", "repos", "sessions", "usage", "gaps", "hook_gaps"].forEach(function (name) {
      demand(Array.isArray(data[name]));
    });
    demand(data.dict && data.hooks && typeof data.hours === "number");
    ["models", "agent_types", "efforts", "personas", "tools", "harnesses", "causes"].forEach(function (name) {
      demand(Array.isArray(data.dict[name]));
    });
    Object.keys(WINDOWS).forEach(function (name) {
      demand(Array.isArray(data.hooks[name]));
    });
    demand(isFinite(Date.parse(data.since)) && isFinite(Date.parse(data.as_of)));
  }

  function union(intervals) {
    var sorted = intervals.slice().sort(function (a, b) {
      return a[0] - b[0] || a[1] - b[1];
    });
    var merged = [];
    sorted.forEach(function (pair) {
      var last = merged[merged.length - 1];
      if (last && pair[0] <= last[1]) {
        last[1] = Math.max(last[1], pair[1]);
      } else {
        merged.push([pair[0], pair[1]]);
      }
    });
    return merged;
  }

  function build(data) {
    var since = Date.parse(data.since) / 1000;
    var asOf = Date.parse(data.as_of) / 1000;
    var position = {};
    COUNTERS.forEach(function (name) {
      var at = data.counters.indexOf(name);
      demand(at >= 0);
      position[name] = at;
    });
    var costColumn = FIRST_COUNTER + data.counters.length;

    function blank() {
      return { requests: 0, rows: 0, counters: {}, cost: null, costed: 0 };
    }

    function add(total, row) {
      total.rows += 1;
      total.requests += row[7];
      COUNTERS.forEach(function (name) {
        var value = row[FIRST_COUNTER + position[name]];
        if (value !== null && value !== undefined) {
          total.counters[name] = (total.counters[name] || 0) + value;
        }
      });
      var cost = row[costColumn];
      if (cost !== null && cost !== undefined) {
        total.cost = (total.cost || 0) + cost;
        total.costed += row[costColumn + 1];
      }
      return total;
    }

    function counter(total, name) {
      var value = total.counters[name];
      return value === undefined ? null : value;
    }

    function word(list, index) {
      return index === null || index === undefined ? null : data.dict[list][index];
    }

    var repos = data.repos.map(function (repo, index) {
      return {
        index: index, name: repo.name, path: repo.path, status: repo.status, lag: repo.lag_seconds,
        lastDerive: repo.last_derive_at, newestRaw: repo.newest_raw_at, dirty: repo.dirty,
        torn: repo.torn_raw === null && repo.torn_derived === null ? null : (repo.torn_raw || 0) + (repo.torn_derived || 0)
      };
    });

    var held = new Map();
    data.sessions.forEach(function (session) {
      held.set(session.key, (held.get(session.key) || 0) + 1);
    });
    var seen = new Map();
    var routes = new Map();

    function routeOf(key, index) {
      var route = encodeURIComponent(key);
      if (held.get(key) > 1) {
        seen.set(key, (seen.get(key) || 0) + 1);
        route += "~" + seen.get(key) + "." + String(data.as_of).replace(/\D/g, "");
      }
      routes.set(route, index);
      return route;
    }

    var sessions = data.sessions.map(function (session, index) {
      demand(Array.isArray(session.agents) && Array.isArray(session.calls) && Array.isArray(session.failures) && Array.isArray(session.active_hours));
      var repo = repos[session.repo];
      demand(repo);
      var harness = word("harnesses", session.harness);
      var spans = [];
      session.agents.forEach(function (agent) {
        agent.spans.forEach(function (span) {
          var from = Math.max(span[0], since);
          var to = Math.min(span[1], asOf);
          if (to >= from) {
            spans.push([from, to]);
          }
        });
      });
      var active = spans.length ? union(spans).reduce(function (sum, pair) {
        return sum + pair[1] - pair[0];
      }, 0) : null;
      return {
        index: index, route: routeOf(session.key, index), key: session.key, repo: session.repo, repoName: repo.name, harness: harness, label: session.label,
        started: session.started === null ? session.first : session.started, ended: session.ended, last: session.last,
        open: session.open === true, home: session.home, activeHours: session.active_hours, agents: session.agents,
        keys: session.agents.map(function (agent) { return agent.key; }),
        calls: session.calls, failures: session.failures, active: active, total: blank(), byAgent: {},
        search: [session.label, repo.name, session.key].filter(Boolean).join("\n").toLowerCase()
      };
    });

    data.usage.forEach(function (row) {
      var session = sessions[row[1]];
      demand(session);
      add(session.total, row);
      add(session.byAgent[row[2]] || (session.byAgent[row[2]] = blank()), row);
    });

    function range(id, prior) {
      var window = WINDOWS[id];
      var low = data.hours - window.hours;
      var high = data.hours - 1;
      if (prior) {
        return window.prior ? [low - window.hours, low - 1] : null;
      }
      return [low, high];
    }

    function inside(hour, span) {
      return hour >= span[0] && hour <= span[1];
    }

    function chosen(repo, index) {
      return repo === null || repo === index;
    }

    function activeIn(session, span) {
      return session.activeHours.some(function (pair) {
        return pair[1] >= span[0] && pair[0] <= span[1];
      });
    }

    function sessionsIn(span, repo) {
      return sessions.filter(function (session) {
        return chosen(repo, session.repo) && activeIn(session, span);
      });
    }

    function usageIn(span, repo) {
      return data.usage.filter(function (row) {
        return inside(row[0], span) && chosen(repo, sessions[row[1]].repo);
      });
    }

    function totalOf(rows) {
      return rows.reduce(add, blank());
    }

    function hourOf(epoch) {
      return Math.floor((epoch - since) / HOUR);
    }

    function failuresIn(span, repo) {
      return sessions.reduce(function (sum, session) {
        if (!chosen(repo, session.repo)) {
          return sum;
        }
        return sum + session.failures.filter(function (failure) {
          return inside(hourOf(failure[0]), span);
        }).length;
      }, 0);
    }

    function gapsIn(span, repo) {
      return data.gaps.filter(function (gap) {
        return inside(gap[0], span) && chosen(repo, gap[1]);
      });
    }

    return {
      raw: data, since: since, asOf: asOf, hours: data.hours, share: data.share === true, repos: repos, sessions: sessions, routes: routes,
      range: range, sessionsIn: sessionsIn, usageIn: usageIn, totalOf: totalOf, blank: blank, add: add, counter: counter,
      word: word, hourOf: hourOf, failuresIn: failuresIn, gapsIn: gapsIn, union: union
    };
  }

  function load(text) {
    var data = JSON.parse(text);
    check(data);
    return build(data);
  }

  T.data = { load: load, WINDOWS: WINDOWS, HOUR: HOUR };
})();
