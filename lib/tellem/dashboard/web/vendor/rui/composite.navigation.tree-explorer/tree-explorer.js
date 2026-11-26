(function () {
  "use strict";
  window.RUI = window.RUI || {};
  RUI.components = RUI.components || {};
  RUI.components["composite.navigation.tree-explorer"] = {
    render(args = {}) {
      const root = document.createElement("div");
      root.className = "rui-tree-explorer";
      root.dataset.ruiComponent = "composite.navigation.tree-explorer";
      root.setAttribute("role", "tree");
      root.setAttribute("aria-label", args.label || "Explorer");
      function forest(input) {
        if (!input.some(node => node.parentId !== undefined)) return input;
        const mapped = new Map();
        for (const node of input) {
          if (mapped.has(node.id)) throw new TypeError("Duplicate tree node ID");
          mapped.set(node.id, {...node, children: []});
        }
        const roots = [];
        for (const node of mapped.values()) {
          if (node.parentId === undefined) roots.push(node);
          else {
            const parent = mapped.get(node.parentId);
            if (!parent) throw new TypeError("Missing tree parent");
            parent.children.push(node);
          }
        }
        const pending = roots.slice();
        let visited = 0;
        while (pending.length) {
          const node = pending.pop();
          visited++;
          for (const child of node.children) pending.push(child);
        }
        if (visited !== mapped.size) throw new TypeError("Cyclic tree");
        return roots;
      }
      let nodes = forest(args.nodes || []);
      let expanded = new Set(args.expanded || []);
      let selected = args.selected || null;
      let active = selected;
      let rows = new Map();

      function emit(type, detail) {
        root.dispatchEvent(new CustomEvent("rui:tree-explorer:" + type, { bubbles: true, detail }));
      }
      function focusNode(id, move = true) {
        const row = rows.get(id);
        if (!row) return;
        const previous = rows.get(active);
        if (previous) previous.element.tabIndex = -1;
        active = id;
        row.element.tabIndex = 0;
        if (move) row.element.focus();
      }
      function draw() {
        const hadFocus = root.contains(document.activeElement);
        const nextRows = new Map();
        const fragment = document.createDocumentFragment();
        function append(list, container, parent, level) {
          for (const node of list) {
            if (!node || typeof node.id !== "string" || !node.id || nextRows.has(node.id)) continue;
            const element = document.createElement("div");
            element.setAttribute("role", "treeitem");
            element.dataset.nodeId = node.id;
            element.tabIndex = -1;
            element.setAttribute("aria-level", String(level));
            element.setAttribute("aria-selected", String(node.id === selected));
            const label = String(node.label ?? node.id);
            element.setAttribute("aria-label", label);
            const line = document.createElement("span");
            line.className = "rui-tree-explorer__row";
            const marker = document.createElement("span");
            marker.className = "rui-tree-explorer__marker";
            marker.setAttribute("aria-hidden", "true");
            const branch = Boolean(node.hasChildren || node.children?.length);
            nextRows.set(node.id, { element, branch, parent });
            if (branch) {
              marker.textContent = expanded.has(node.id) ? "▾" : "▸";
              marker.dataset.toggle = "";
              element.setAttribute("aria-expanded", String(expanded.has(node.id)));
            }
            line.append(marker, document.createTextNode(label));
            element.append(line);
            container.append(element);
            if (branch && expanded.has(node.id) && Array.isArray(node.children)) {
              const group = document.createElement("div");
              group.setAttribute("role", "group");
              element.append(group);
              append(node.children, group, node.id, level + 1);
            }
          }
        }
        append(nodes, fragment, null, 1);
        let next = active;
        while (next && !nextRows.has(next)) next = rows.get(next)?.parent;
        rows = nextRows;
        root.replaceChildren(fragment);
        active = null;
        focusNode(next || rows.keys().next().value, hadFocus);
      }
      function toggle(id) {
        if (expanded.has(id)) expanded.delete(id);
        else expanded.add(id);
        draw();
        emit("expand", { id, expanded: expanded.has(id) });
      }
      function activate(id) {
        const last = rows.get(selected);
        if (last) last.element.setAttribute("aria-selected", "false");
        selected = id;
        rows.get(id).element.setAttribute("aria-selected", "true");
        emit("activate", { id });
      }
      root.addEventListener("focusin", event => {
        const item = event.target.closest("[role=treeitem]");
        if (item) focusNode(item.dataset.nodeId, false);
      });
      root.addEventListener("click", event => {
        const item = event.target.closest("[role=treeitem]");
        if (!item) return;
        const id = item.dataset.nodeId;
        focusNode(id);
        if (event.target.closest("[data-toggle]")) toggle(id);
        else activate(id);
      });
      root.addEventListener("keydown", event => {
        const row = rows.get(active);
        if (!row || event.altKey || event.ctrlKey || event.metaKey) return;
        const ids = Array.from(rows.keys());
        const index = ids.indexOf(active);
        switch (event.key) {
          case "Home": focusNode(ids[0]); break;
          case "End": focusNode(ids.at(-1)); break;
          case "ArrowDown": focusNode(ids[index + 1]); break;
          case "ArrowUp": focusNode(ids[index - 1]); break;
          case "ArrowLeft":
            if (row.branch && expanded.has(active)) toggle(active);
            else focusNode(row.parent);
            break;
          case "ArrowRight":
            if (row.branch && !expanded.has(active)) toggle(active);
            else if (rows.get(ids[index + 1])?.parent === active) focusNode(ids[index + 1]);
            break;
          case "Enter":
          case " ": activate(active); break;
          default: return;
        }
        event.preventDefault();
      });
      root.setNodes = function (list) {
        if (!Array.isArray(list)) throw new TypeError("nodes must be an array");
        nodes = forest(list);
        draw();
      };
      draw();
      return root;
    }
  };
})();
