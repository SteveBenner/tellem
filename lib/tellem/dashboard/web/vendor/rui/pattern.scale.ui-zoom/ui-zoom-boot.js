(function () {
  try {
    var value = parseFloat(localStorage.getItem('rui:pattern.scale.ui-zoom'));
    if (!isFinite(value)) return;
    value = Math.min(2.5, Math.max(0.75, value));
    value = Math.round(value * 20) / 20;
    if (value !== 1) {
      document.documentElement.style.setProperty('--rui-ui-zoom-scale', String(value));
    }
  } catch (error) {
  }
})();
