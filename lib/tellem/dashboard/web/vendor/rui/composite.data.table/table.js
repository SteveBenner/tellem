(function () {
  "use strict";
  window.RUI = window.RUI || {};
  RUI.components = RUI.components || {};

  var ID = "composite.data.table";
  var NS = "http://www.w3.org/2000/svg";
  var ICONS = {
    up: "M205.66,117.66a8,8,0,0,1-11.32,0L136,59.31V216a8,8,0,0,1-16,0V59.31L61.66,117.66a8,8,0,0,1-11.32-11.32l72-72a8,8,0,0,1,11.32,0l72,72A8,8,0,0,1,205.66,117.66Z",
    down: "M205.66,149.66l-72,72a8,8,0,0,1-11.32,0l-72-72a8,8,0,0,1,11.32-11.32L120,196.69V40a8,8,0,0,1,16,0V196.69l58.34-58.35a8,8,0,0,1,11.32,11.32Z"
  };
  var DENSITIES = ["compact", "cockpit", "application", "reading"];

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

  function icon(name) {
    var node = document.createElementNS(NS, "svg");
    node.setAttribute("class", "rui-table__icon");
    node.setAttribute("viewBox", "0 0 256 256");
    node.setAttribute("fill", "currentColor");
    node.setAttribute("aria-hidden", "true");
    node.setAttribute("focusable", "false");
    var path = document.createElementNS(NS, "path");
    path.setAttribute("d", ICONS[name]);
    node.appendChild(path);
    return node;
  }

  function isNum(v) {
    return typeof v === "number" && isFinite(v);
  }

  function absent(v) {
    return v === null || v === undefined || v === "";
  }

  function hiddenText(text) {
    return el("span", "rui-table__sr", text);
  }

  function plural(count, one, many) {
    return count + " " + (count === 1 ? one : many);
  }

  function describeSort(col, dir, count) {
    if (!dir) {
      return "Sorted in the default order. " + plural(count, "row", "rows") + ".";
    }
    var name = col.label.toLowerCase();
    var tail = col.kind === "number"
      ? (dir === "ascending" ? "lowest" : "highest") + " first"
      : (dir === "ascending" ? "A to Z" : "Z to A");
    return "Sorted by " + name + ", " + tail + ". " + plural(count, "row", "rows") + ".";
  }

  RUI.components["composite.data.table"] = {
    render: function (args, ctx) {
      var columns = (Array.isArray(args.columns) ? args.columns : []).map(function (c, i) {
        var kind = c.type === "number" || c.type === "datetime" ? c.type : "text";
        return {
          key: c.key,
          label: c.label,
          kind: kind,
          end: c.align === "end" || (c.align !== "start" && kind === "number"),
          sortable: c.sortable === true,
          structural: c.structural === true,
          identity: c.identity === true,
          hidden: c.hidden === true,
          index: i
        };
      });
      var rows = Array.isArray(args.rows) ? args.rows : [];
      var rowKey = typeof args.row_key === "string" ? args.row_key : "";
      var mode = args.selection === "single" || args.selection === "multi" ? args.selection : "none";
      var density = DENSITIES.indexOf(args.density) >= 0 ? args.density : "cockpit";
      var absentText = typeof args.absent_text === "string" ? args.absent_text : "None";
      var hasAction = args.row_action !== null && args.row_action !== undefined;
      var identityCol = columns.filter(function (c) { return c.identity; })[0] || columns[0];
      if (identityCol) {
        identityCol.structural = true;
      }
      var defaultSort = args.sort && args.sort.key
        ? { key: args.sort.key, direction: args.sort.direction === "descending" ? "descending" : "ascending" }
        : null;
      var current = defaultSort;
      var atDefault = true;

      var entries = rows.map(function (row, index) {
        return { row: row, index: index, key: rowKey !== "" && !absent(row[rowKey]) ? String(row[rowKey]) : String(index) };
      });
      var selected = {};
      (Array.isArray(args.selected) ? args.selected : []).forEach(function (k) {
        var key = String(k);
        if (entries.some(function (e) { return e.key === key; })) {
          selected[key] = true;
        }
      });
      if (mode === "single") {
        var keep = Object.keys(selected)[0];
        selected = {};
        if (keep !== undefined) {
          selected[keep] = true;
        }
      }
      var order = entries.slice();
      var anchor = null;
      var rangeHandled = false;

      var root = el("div", "rui-table");
      root.setAttribute("data-rui-component", ID);
      root.setAttribute("data-density", density);
      if (args.sticky_header === true) {
        root.setAttribute("data-sticky", "true");
      }
      var captionId = ctx.uid("caption");
      var groupName = ctx.uid("select");

      var live = el("div", "rui-table__sr");
      live.setAttribute("role", "status");
      live.setAttribute("aria-live", "polite");
      function announce(text) {
        live.textContent = "";
        live.textContent = text;
      }

      var toolbar = null;
      var status = null;
      var clearButton = null;
      var colButton = null;
      var colPanel = null;
      if (mode !== "none" || args.column_control === true) {
        toolbar = el("div", "rui-table__toolbar");
        status = el("span", "rui-table__status");
        toolbar.appendChild(status);
        if (mode !== "none") {
          clearButton = el("button", "rui-table__button", "Clear selection");
          clearButton.type = "button";
          clearButton.addEventListener("click", function () {
            selected = {};
            anchor = null;
            refreshSelection(true);
            clearButton.blur();
          });
          toolbar.appendChild(clearButton);
        }
        toolbar.appendChild(el("span", "rui-table__spacer"));
        root.appendChild(toolbar);
      }

      var region = el("div", "rui-table__region");
      region.setAttribute("role", "region");
      region.setAttribute("aria-labelledby", captionId);
      region.tabIndex = 0;
      if (typeof args.max_height === "string" && args.max_height !== "") {
        region.style.setProperty("--rui-table-max-height", args.max_height);
      }
      var table = el("table", "rui-table__table");
      var caption = el("caption", args.caption !== "" && args.caption ? "rui-table__caption" : "rui-table__sr", args.caption || "Table");
      caption.id = captionId;
      table.appendChild(caption);
      var thead = el("thead");
      var tbody = el("tbody");
      table.appendChild(thead);
      table.appendChild(tbody);
      region.appendChild(table);
      root.appendChild(region);
      root.appendChild(live);

      var headers = {};
      var headCheck = null;
      var rowChecks = {};
      var rowNodes = {};

      function visibleColumns() {
        return columns.filter(function (c) { return !c.hidden; });
      }

      function identityText(entry) {
        if (!identityCol) {
          return String(entry.index + 1);
        }
        var v = entry.row[identityCol.key];
        return absent(v) ? String(entry.index + 1) : String(v);
      }

      function selectedCount() {
        return Object.keys(selected).length;
      }

      function emitSelect() {
        if (args.on_select) {
          ctx.emit(args.on_select, { keys: Object.keys(selected), count: selectedCount() });
        }
      }

      function refreshSelection(announceIt) {
        var count = selectedCount();
        entries.forEach(function (e) {
          var node = rowNodes[e.key];
          var box = rowChecks[e.key];
          var on = selected[e.key] === true;
          if (node) {
            if (on) {
              node.setAttribute("data-selected", "true");
            } else {
              node.removeAttribute("data-selected");
            }
          }
          if (box) {
            box.checked = on;
          }
        });
        if (headCheck) {
          headCheck.checked = count > 0 && count === entries.length;
          headCheck.indeterminate = count > 0 && count < entries.length;
        }
        if (status) {
          status.textContent = mode === "none"
            ? ""
            : (count === 0 ? "None selected" : count + " selected of " + plural(entries.length, "row", "rows") + " on this page");
        }
        if (clearButton) {
          clearButton.disabled = count === 0;
        }
        if (announceIt) {
          announce(count === 0 ? "Selection cleared." : count + " selected of " + plural(entries.length, "row", "rows") + ".");
          emitSelect();
        }
      }

      function setRange(fromKey, toKey, on) {
        var a = order.map(function (e) { return e.key; }).indexOf(fromKey);
        var b = order.map(function (e) { return e.key; }).indexOf(toKey);
        if (a < 0 || b < 0) {
          return;
        }
        var lo = Math.min(a, b);
        var hi = Math.max(a, b);
        for (var i = lo; i <= hi; i += 1) {
          if (on) {
            selected[order[i].key] = true;
          } else {
            delete selected[order[i].key];
          }
        }
      }

      function toggle(entry, on, range) {
        if (mode === "single") {
          selected = {};
          selected[entry.key] = true;
          anchor = entry.key;
        } else if (range && anchor !== null) {
          setRange(anchor, entry.key, on);
          anchor = entry.key;
        } else {
          if (on) {
            selected[entry.key] = true;
          } else {
            delete selected[entry.key];
          }
          anchor = entry.key;
        }
        refreshSelection(true);
      }

      function sortedEntries() {
        var list = entries.slice();
        if (!current) {
          return list;
        }
        var col = columns.filter(function (c) { return c.key === current.key; })[0];
        if (!col) {
          return list;
        }
        var sign = current.direction === "ascending" ? 1 : -1;
        list.sort(function (a, b) {
          var av = a.row[col.key];
          var bv = b.row[col.key];
          var ae = absent(av);
          var be = absent(bv);
          if (ae !== be) {
            return ae ? 1 : -1;
          }
          var cmp = 0;
          if (!ae) {
            cmp = isNum(av) && isNum(bv) ? av - bv : String(av).localeCompare(String(bv), undefined, { numeric: true });
          }
          if (cmp !== 0) {
            return sign * cmp;
          }
          var tie = identityText(a).localeCompare(identityText(b), undefined, { numeric: true });
          return tie !== 0 ? tie : a.index - b.index;
        });
        return list;
      }

      function cellClass(col) {
        return "rui-table__cell" + (col.end ? " rui-table__cell--end" : "") + (col.kind !== "text" ? " rui-table__cell--figures" : "");
      }

      function selectBox(label) {
        var wrap = el("label", "rui-table__check");
        var input = el("input", "rui-table__input");
        input.type = mode === "single" ? "radio" : "checkbox";
        if (mode === "single") {
          input.name = groupName;
        }
        input.setAttribute("aria-label", label);
        wrap.appendChild(input);
        return { wrap: wrap, input: input };
      }

      function paintSortMarks() {
        columns.forEach(function (col) {
          var h = headers[col.key];
          if (!h) {
            return;
          }
          h.mark.replaceChildren();
          if (current && current.key === col.key) {
            h.th.setAttribute("aria-sort", current.direction);
            h.mark.appendChild(icon(current.direction === "ascending" ? "up" : "down"));
          } else {
            h.th.removeAttribute("aria-sort");
          }
        });
      }

      function buildHead() {
        thead.replaceChildren();
        headers = {};
        headCheck = null;
        var tr = el("tr");
        if (mode !== "none") {
          var sth = el("th", "rui-table__cell rui-table__cell--select");
          sth.setAttribute("scope", "col");
          if (mode === "multi") {
            var all = selectBox("Select all " + plural(entries.length, "row", "rows") + " on this page");
            headCheck = all.input;
            headCheck.addEventListener("change", function () {
              if (headCheck.checked) {
                entries.forEach(function (e) { selected[e.key] = true; });
              } else {
                selected = {};
              }
              anchor = null;
              refreshSelection(true);
            });
            sth.appendChild(all.wrap);
          } else {
            sth.appendChild(hiddenText("Select"));
          }
          tr.appendChild(sth);
        }
        visibleColumns().forEach(function (col) {
          var th = el("th", cellClass(col));
          th.setAttribute("scope", "col");
          if (col.sortable) {
            var button = el("button", "rui-table__sort");
            button.type = "button";
            button.appendChild(el("span", "rui-table__sort-label", col.label));
            var mark = el("span", "rui-table__sort-mark");
            mark.setAttribute("aria-hidden", "true");
            button.appendChild(mark);
            button.addEventListener("click", function () {
              if (atDefault || !current || current.key !== col.key) {
                current = { key: col.key, direction: "ascending" };
                atDefault = false;
              } else if (current.direction === "ascending") {
                current = { key: col.key, direction: "descending" };
              } else {
                current = defaultSort;
                atDefault = true;
              }
              paintSortMarks();
              buildBody();
              var active = current ? columns.filter(function (c) { return c.key === current.key; })[0] : col;
              var text = describeSort(active, current && !atDefault ? current.direction : null, entries.length);
              announce(text);
              if (args.on_sort) {
                ctx.emit(args.on_sort, {
                  key: current ? current.key : null,
                  direction: current ? current.direction : null,
                  announcement: text
                });
              }
              if (colPanel) {
                buildPanel();
              }
            });
            th.appendChild(button);
            headers[col.key] = { th: th, mark: mark };
          } else {
            th.textContent = col.label;
          }
          tr.appendChild(th);
        });
        if (hasAction) {
          var ath = el("th", "rui-table__cell");
          ath.setAttribute("scope", "col");
          ath.appendChild(hiddenText("Actions"));
          tr.appendChild(ath);
        }
        thead.appendChild(tr);
        paintSortMarks();
      }

      function buildBody() {
        tbody.replaceChildren();
        rowChecks = {};
        rowNodes = {};
        var cols = visibleColumns();
        order = sortedEntries();
        if (entries.length === 0) {
          var emptyRow = el("tr");
          var emptyCell = el("td", "rui-table__cell rui-table__empty", args.empty);
          emptyCell.setAttribute("colspan", String(Math.max(1, cols.length + (mode !== "none" ? 1 : 0) + (hasAction ? 1 : 0))));
          emptyRow.appendChild(emptyCell);
          tbody.appendChild(emptyRow);
          return;
        }
        order.forEach(function (entry) {
          var tr = el("tr", "rui-table__row");
          rowNodes[entry.key] = tr;
          if (mode !== "none") {
            var std = el("td", "rui-table__cell rui-table__cell--select");
            var box = selectBox("Select " + identityText(entry));
            rowChecks[entry.key] = box.input;
            box.input.addEventListener("click", function (event) {
              if (rangeHandled) {
                rangeHandled = false;
                event.preventDefault();
                return;
              }
              toggle(entry, box.input.checked, event.shiftKey === true);
            });
            box.input.addEventListener("keydown", function (event) {
              if (mode === "multi" && event.shiftKey && (event.key === " " || event.code === "Space")) {
                event.preventDefault();
                rangeHandled = true;
                window.setTimeout(function () { rangeHandled = false; }, 0);
                toggle(entry, selected[entry.key] !== true, true);
                if (anchor !== null) {
                  box.input.focus();
                }
              }
            });
            std.appendChild(box.wrap);
            tr.appendChild(std);
          }
          cols.forEach(function (col) {
            var isId = col === identityCol;
            var td = el(isId ? "th" : "td", cellClass(col));
            if (isId) {
              td.setAttribute("scope", "row");
            }
            var value = entry.row[col.key];
            if (absent(value)) {
              td.className += " rui-table__cell--dim";
              td.textContent = absentText;
            } else {
              td.textContent = String(value);
            }
            tr.appendChild(td);
          });
          if (hasAction) {
            var atd = el("td", "rui-table__cell");
            var open = el("button", "rui-table__open", "Open");
            open.type = "button";
            open.setAttribute("aria-label", "Open " + identityText(entry));
            open.addEventListener("click", function () {
              var values = {};
              Object.keys(entry.row).forEach(function (key) {
                values[key] = entry.row[key];
              });
              ctx.emit(args.row_action, values);
            });
            atd.appendChild(open);
            tr.appendChild(atd);
          }
          tbody.appendChild(tr);
        });
        refreshSelection(false);
      }

      function buildPanel() {
        colPanel.replaceChildren();
        columns.forEach(function (col) {
          if (col.structural) {
            return;
          }
          var label = el("label", "rui-table__option");
          var input = el("input", "rui-table__input");
          input.type = "checkbox";
          input.checked = !col.hidden;
          var locked = current && current.key === col.key;
          input.disabled = locked === true;
          label.appendChild(input);
          label.appendChild(el("span", "rui-table__option-label", col.label));
          if (locked) {
            label.appendChild(el("span", "rui-table__option-reason", "Sorted by this column"));
          }
          input.addEventListener("change", function () {
            col.hidden = !input.checked;
            buildHead();
            buildBody();
            var hiddenKeys = columns.filter(function (c) { return c.hidden; }).map(function (c) { return c.key; });
            announce(col.label + (col.hidden ? " hidden. " : " shown. ") + plural(visibleColumns().length, "column", "columns") + " visible.");
            if (args.on_columns) {
              ctx.emit(args.on_columns, { hidden: hiddenKeys });
            }
          });
          colPanel.appendChild(label);
        });
      }

      if (args.column_control === true && toolbar) {
        var wrap = el("div", "rui-table__columns");
        var panelId = ctx.uid("columns");
        colButton = el("button", "rui-table__button", "Columns");
        colButton.type = "button";
        colButton.setAttribute("aria-expanded", "false");
        colButton.setAttribute("aria-controls", panelId);
        colPanel = el("div", "rui-table__panel");
        colPanel.id = panelId;
        colPanel.setAttribute("role", "group");
        colPanel.setAttribute("aria-label", "Visible columns");
        colPanel.hidden = true;
        function closePanel(refocus) {
          colPanel.hidden = true;
          colButton.setAttribute("aria-expanded", "false");
          if (refocus) {
            colButton.focus();
          }
        }
        colButton.addEventListener("click", function () {
          if (colPanel.hidden) {
            buildPanel();
            colPanel.hidden = false;
            colButton.setAttribute("aria-expanded", "true");
          } else {
            closePanel(false);
          }
        });
        wrap.addEventListener("keydown", function (event) {
          if (event.key === "Escape" && !colPanel.hidden) {
            event.stopPropagation();
            closePanel(true);
          }
        });
        wrap.addEventListener("focusout", function (event) {
          if (!colPanel.hidden && event.relatedTarget && !wrap.contains(event.relatedTarget)) {
            closePanel(false);
          }
        });
        wrap.appendChild(colButton);
        wrap.appendChild(colPanel);
        toolbar.appendChild(wrap);
      }

      buildHead();
      buildBody();
      refreshSelection(false);
      return root;
    }
  };
})();
