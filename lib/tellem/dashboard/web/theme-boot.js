(function () {
  var themes = ["apple-noir", "apple-austere", "tronwave", "minimal-dark", "minimal-light"];
  var chosen = null;
  try {
    chosen = localStorage.getItem("tellem.dashboard.theme");
  } catch (error) {
    chosen = null;
  }
  if (themes.indexOf(chosen) < 0) {
    try {
      chosen = window.matchMedia("(prefers-color-scheme: light)").matches ? "minimal-light" : "minimal-dark";
    } catch (error) {
      chosen = "minimal-dark";
    }
  }
  document.documentElement.setAttribute("data-theme", chosen);
})();
