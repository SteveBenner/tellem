(function () {
  'use strict';

  var MIN = 0.75;
  var MAX = 2.5;
  var STEP = 0.05;
  var DEFAULT = 1;
  var KEY = 'rui:pattern.scale.ui-zoom';
  var PROPERTY = '--rui-ui-zoom-scale';
  var TOAST_MS = 1100;

  var root = document.documentElement;
  var scale = DEFAULT;
  var controls = [];
  var toast = null;
  var toastTimer = null;
  var wheelAccumulated = 0;
  var wheelSteps = 0;
  var wheelFrame = null;

  function normalise(value) {
    var number = typeof value === 'number' ? value : parseFloat(value);
    if (!isFinite(number)) return DEFAULT;
    number = Math.min(MAX, Math.max(MIN, number));
    return Math.round(number * 20) / 20;
  }

  function percent() {
    return Math.round(scale * 100);
  }

  function readStored() {
    try {
      return normalise(localStorage.getItem(KEY));
    } catch (error) {
      return DEFAULT;
    }
  }

  function writeStored() {
    try {
      if (scale === DEFAULT) {
        localStorage.removeItem(KEY);
      } else {
        localStorage.setItem(KEY, String(scale));
      }
    } catch (error) {
    }
  }

  function applyProperty() {
    if (scale === DEFAULT) {
      root.style.removeProperty(PROPERTY);
    } else {
      root.style.setProperty(PROPERTY, String(scale));
    }
  }

  function get() {
    return scale;
  }

  function toCss(px) {
    return px / scale;
  }

  function rect(element) {
    var box = element.getBoundingClientRect();
    return {
      x: box.x / scale,
      y: box.y / scale,
      width: box.width / scale,
      height: box.height / scale,
      top: box.top / scale,
      right: box.right / scale,
      bottom: box.bottom / scale,
      left: box.left / scale
    };
  }

  function presetValue(item) {
    return parseInt(item.getAttribute('data-rui-ui-zoom-preset'), 10);
  }

  function updateControl(control) {
    var value = percent();
    control.button.textContent = value + '%';
    control.button.setAttribute('aria-label', 'Interface scale ' + value + ' percent');
    if (control.down) control.down.setAttribute('aria-disabled', scale <= MIN ? 'true' : 'false');
    if (control.up) control.up.setAttribute('aria-disabled', scale >= MAX ? 'true' : 'false');
    for (var i = 0; i < control.presets.length; i++) {
      var item = control.presets[i];
      item.setAttribute('aria-checked', presetValue(item) === value ? 'true' : 'false');
    }
  }

  function updateControls() {
    for (var i = 0; i < controls.length; i++) updateControl(controls[i]);
  }

  function set(value, source) {
    var next = normalise(value);
    if (next === scale) return;
    scale = next;
    applyProperty();
    if (source !== 'storage') writeStored();
    updateControls();
    document.dispatchEvent(new CustomEvent('rui:ui-zoom:change', {
      detail: { scale: scale, source: source || 'api' }
    }));
  }

  function stepBy(direction, source) {
    var sign = direction < 0 ? -1 : 1;
    set((percent() + sign * Math.round(STEP * 100)) / 100, source);
  }

  function step(direction) {
    stepBy(direction, 'api');
  }

  function ensureToast() {
    if (toast) return toast;
    toast = document.createElement('div');
    toast.className = 'rui-ui-zoom__toast';
    toast.setAttribute('role', 'status');
    toast.setAttribute('aria-live', 'polite');
    document.body.appendChild(toast);
    return toast;
  }

  function showToast() {
    var element = ensureToast();
    element.textContent = percent() + '%';
    var hint = document.createElement('span');
    hint.textContent = 'Alt + wheel';
    element.appendChild(hint);
    void element.offsetWidth;
    element.classList.add('is-visible');
    clearTimeout(toastTimer);
    toastTimer = setTimeout(function () {
      element.classList.remove('is-visible');
    }, TOAST_MS);
  }

  function flushWheel() {
    wheelFrame = null;
    var steps = wheelSteps;
    wheelSteps = 0;
    if (steps !== 0) set((percent() + steps * Math.round(STEP * 100)) / 100, 'wheel');
    showToast();
  }

  function onWheel(event) {
    if (!event.altKey || event.ctrlKey || event.metaKey) return;
    event.preventDefault();
    var delta = event.deltaY;
    if (event.deltaMode === 1) delta *= 16;
    else if (event.deltaMode === 2) delta *= 400;
    wheelAccumulated += delta;
    while (wheelAccumulated <= -100) {
      wheelSteps += 1;
      wheelAccumulated += 100;
    }
    while (wheelAccumulated >= 100) {
      wheelSteps -= 1;
      wheelAccumulated -= 100;
    }
    if (wheelFrame === null) wheelFrame = requestAnimationFrame(flushWheel);
  }

  function onStorage(event) {
    if (event.key !== KEY) return;
    set(event.newValue === null ? DEFAULT : event.newValue, 'storage');
  }

  function isOpen(control) {
    return !control.menu.hidden;
  }

  function currentItem(control) {
    var value = percent();
    var best = control.presets[0];
    var distance = Infinity;
    for (var i = 0; i < control.presets.length; i++) {
      var gap = Math.abs(presetValue(control.presets[i]) - value);
      if (gap < distance) {
        distance = gap;
        best = control.presets[i];
      }
    }
    return best;
  }

  function openMenu(control, focusItem) {
    for (var i = 0; i < controls.length; i++) {
      if (controls[i] !== control) closeMenu(controls[i], false);
    }
    control.menu.hidden = false;
    control.button.setAttribute('aria-expanded', 'true');
    if (focusItem) focusItem.focus();
  }

  function closeMenu(control, returnFocus) {
    if (!isOpen(control)) return;
    control.menu.hidden = true;
    control.button.setAttribute('aria-expanded', 'false');
    if (returnFocus) control.button.focus();
  }

  function moveFocus(control, offset) {
    var items = control.presets;
    var index = items.indexOf(document.activeElement);
    if (index === -1) index = items.indexOf(currentItem(control));
    items[(index + offset + items.length) % items.length].focus();
  }

  function onMenuKey(control, event) {
    switch (event.key) {
      case 'ArrowDown':
        event.preventDefault();
        moveFocus(control, 1);
        break;
      case 'ArrowUp':
        event.preventDefault();
        moveFocus(control, -1);
        break;
      case 'Home':
        event.preventDefault();
        control.presets[0].focus();
        break;
      case 'End':
        event.preventDefault();
        control.presets[control.presets.length - 1].focus();
        break;
      case 'Escape':
        event.preventDefault();
        closeMenu(control, true);
        break;
      case 'Tab':
        closeMenu(control, false);
        break;
    }
  }

  function onButtonKey(control, event) {
    if (event.key === 'ArrowDown') {
      event.preventDefault();
      openMenu(control, currentItem(control));
    } else if (event.key === 'ArrowUp') {
      event.preventDefault();
      openMenu(control, control.presets[control.presets.length - 1]);
    } else if (event.key === 'Escape' && isOpen(control)) {
      event.preventDefault();
      closeMenu(control, true);
    }
  }

  function onDocumentPointer(event) {
    for (var i = 0; i < controls.length; i++) {
      if (!controls[i].element.contains(event.target)) closeMenu(controls[i], false);
    }
  }

  function enhance(element) {
    if (element.hasAttribute('data-rui-ui-zoom-ready')) return;
    var control = {
      element: element,
      down: element.querySelector('[data-rui-ui-zoom-step="-1"]'),
      up: element.querySelector('[data-rui-ui-zoom-step="1"]'),
      button: element.querySelector('.rui-ui-zoom__value'),
      menu: element.querySelector('.rui-ui-zoom__menu'),
      presets: Array.prototype.slice.call(element.querySelectorAll('[data-rui-ui-zoom-preset]'))
    };
    if (!control.button || !control.menu || control.presets.length === 0) return;
    element.setAttribute('data-rui-ui-zoom-ready', '');
    element.removeAttribute('hidden');
    [control.down, control.up].forEach(function (stepper) {
      if (!stepper) return;
      stepper.addEventListener('click', function () {
        if (stepper.getAttribute('aria-disabled') === 'true') return;
        closeMenu(control, false);
        stepBy(parseInt(stepper.getAttribute('data-rui-ui-zoom-step'), 10), 'control');
      });
    });
    control.button.addEventListener('click', function (event) {
      if (isOpen(control)) closeMenu(control, false);
      else openMenu(control, event.detail === 0 ? currentItem(control) : null);
    });
    control.button.addEventListener('keydown', function (event) {
      onButtonKey(control, event);
    });
    control.presets.forEach(function (item) {
      item.addEventListener('click', function () {
        set(presetValue(item) / 100, 'preset');
        closeMenu(control, true);
      });
    });
    control.menu.addEventListener('keydown', function (event) {
      onMenuKey(control, event);
    });
    controls.push(control);
    updateControl(control);
  }

  function init() {
    scale = readStored();
    applyProperty();
    var elements = document.querySelectorAll('[data-rui-ui-zoom]');
    for (var i = 0; i < elements.length; i++) enhance(elements[i]);
  }

  window.RUI = window.RUI || {};
  window.RUI.uiZoom = {
    get: get,
    set: set,
    step: step,
    toCss: toCss,
    rect: rect
  };

  document.addEventListener('wheel', onWheel, { passive: false });
  document.addEventListener('pointerdown', onDocumentPointer, true);
  window.addEventListener('storage', onStorage);

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
})();
