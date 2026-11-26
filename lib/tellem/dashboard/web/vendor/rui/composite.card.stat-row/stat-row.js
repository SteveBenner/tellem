(function () {
  "use strict";
  window.RUI = window.RUI || {};
  RUI.components = RUI.components || {};

  RUI.components["composite.card.stat-row"] = {
    render: function (args, ctx) {
      var root = document.createElement("div");
      root.className = "rui-stat-row";
      root.setAttribute("data-rui-component", "composite.card.stat-row");
      root.setAttribute("role", "group");
      root.setAttribute("aria-label", "Key figures");
      var tiles = (args.tiles || []).slice(0, 6);
      if (tiles.length === 0) {
        var empty = document.createElement("p");
        empty.className = "rui-stat-row__empty";
        empty.textContent = "No figures";
        root.appendChild(empty);
        return root;
      }
      tiles.forEach(function (tile, index) {
        var cell = document.createElement("div");
        cell.className = "rui-stat-row__cell";
        var merged = Object.assign({}, tile, { framed: false, focus: index === args.focus });
        cell.appendChild(ctx.compose("composite.card.kpi", merged));
        root.appendChild(cell);
      });
      return root;
    }
  };
})();
