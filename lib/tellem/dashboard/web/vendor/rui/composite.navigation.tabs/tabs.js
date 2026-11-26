(function () {
  "use strict";
  window.RUI = window.RUI || {};
  RUI.components = RUI.components || {};

  RUI.components["composite.navigation.tabs"] = {
    render: function (args, ctx) {
      var root = document.createElement("div");
      root.className = "rui-tabs";
      root.setAttribute("data-rui-component", "composite.navigation.tabs");

      var list = document.createElement("div");
      list.className = "rui-tabs__list";
      list.setAttribute("role", "tablist");
      list.setAttribute("aria-label", "Tabs");
      root.appendChild(list);

      var tabs = [];
      var panels = [];
      var selected = 0;
      args.tabs.forEach(function (spec, index) {
        if (spec.key === args.selected) {
          selected = index;
        }
      });

      function choose(index, focus) {
        selected = index;
        tabs.forEach(function (tab, i) {
          var on = i === index;
          tab.setAttribute("aria-selected", on ? "true" : "false");
          tab.setAttribute("tabindex", on ? "0" : "-1");
          if (on) {
            panels[i].removeAttribute("hidden");
          } else {
            panels[i].setAttribute("hidden", "");
          }
        });
        if (focus) {
          tabs[index].focus();
        }
      }

      args.tabs.forEach(function (spec, index) {
        var tabId = ctx.uid("tab-" + index);
        var panelId = ctx.uid("panel-" + index);
        var tab = document.createElement("button");
        tab.type = "button";
        tab.className = "rui-tabs__tab";
        tab.id = tabId;
        tab.setAttribute("role", "tab");
        tab.setAttribute("aria-controls", panelId);
        tab.textContent = spec.label;
        tab.addEventListener("click", function () {
          choose(index, false);
        });
        tab.addEventListener("keydown", function (event) {
          var count = tabs.length;
          var next = -1;
          if (event.key === "ArrowRight") {
            next = (index + 1) % count;
          } else if (event.key === "ArrowLeft") {
            next = (index - 1 + count) % count;
          } else if (event.key === "Home") {
            next = 0;
          } else if (event.key === "End") {
            next = count - 1;
          }
          if (next >= 0) {
            event.preventDefault();
            choose(next, true);
          }
        });
        list.appendChild(tab);
        tabs.push(tab);

        var panel = document.createElement("div");
        panel.className = "rui-tabs__panel";
        panel.id = panelId;
        panel.setAttribute("role", "tabpanel");
        panel.setAttribute("aria-labelledby", tabId);
        panel.setAttribute("tabindex", "0");
        panel.setAttribute("data-rui-slot", spec.key);
        root.appendChild(panel);
        panels.push(panel);
      });

      if (tabs.length > 0) {
        choose(selected, false);
      }
      return root;
    }
  };
})();
