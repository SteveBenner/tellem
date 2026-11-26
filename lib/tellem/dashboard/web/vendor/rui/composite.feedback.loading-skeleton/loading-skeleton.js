(function () {
  "use strict";
  window.RUI = window.RUI || {};
  RUI.components = RUI.components || {};
  RUI.components["composite.feedback.loading-skeleton"] = {
    render(args = {}) {
      const root = document.createElement("div");
      root.className = "rui-loading-skeleton";
      root.dataset.ruiComponent = "composite.feedback.loading-skeleton";
      const variant = args.variant === "rows" ? "rows" : "lines";
      root.dataset.variant = variant;
      const count = Number.isInteger(args.count) ? Math.max(1, Math.min(32, args.count)) : 3;
      if (typeof args.label === "string" && args.label.trim()) {
        const status = document.createElement("span");
        status.className = "rui-loading-skeleton__status";
        status.setAttribute("role", "status");
        status.textContent = args.label;
        root.append(status);
      }
      const shapes = document.createElement("div");
      shapes.className = "rui-loading-skeleton__shapes";
      shapes.setAttribute("aria-hidden", "true");
      shapes.inert = true;
      for (let i = 0; i < count; i += 1) shapes.append(document.createElement("span"));
      root.append(shapes);
      return root;
    }
  };
})();
