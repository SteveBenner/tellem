(function () {
  "use strict";
  window.RUI = window.RUI || {};
  RUI.components = RUI.components || {};

  function part(tag, cls, text) {
    var node = document.createElement(tag);
    node.className = cls;
    node.textContent = text;
    return node;
  }

  function item(entry, index, args) {
    var li = document.createElement("li");
    li.className = "rui-ranked-list__item";
    var rank = part("span", "rui-ranked-list__rank", String(index + 1));
    rank.setAttribute("aria-hidden", "true");
    li.appendChild(rank);
    var label = part("span", "rui-ranked-list__label", "");
    if (entry.href) {
      var link = part("a", "rui-ranked-list__link", entry.label);
      link.setAttribute("href", entry.href);
      label.appendChild(link);
    } else {
      label.appendChild(document.createTextNode(entry.label));
    }
    if (entry.note) {
      label.appendChild(part("span", "rui-ranked-list__note", entry.note));
    }
    li.appendChild(label);
    var value = part("span", "rui-ranked-list__value", "");
    if (args.value_label) {
      value.appendChild(part("span", "rui-ranked-list__sr", args.value_label + ": "));
    }
    value.appendChild(document.createTextNode(entry.value));
    li.appendChild(value);
    if (typeof entry.share === "number" && entry.share >= 0 && entry.share <= 1) {
      var bar = part("span", "rui-ranked-list__bar", "");
      bar.setAttribute("aria-hidden", "true");
      var fill = part("span", "rui-ranked-list__fill", "");
      fill.style.setProperty("--rui-ranked-list-share", (entry.share * 100) + "%");
      bar.appendChild(fill);
      li.appendChild(bar);
    }
    return li;
  }

  RUI.components["composite.data.ranked-list"] = {
    render: function (args, ctx) {
      var root = document.createElement("div");
      root.className = "rui-ranked-list";
      root.setAttribute("data-rui-component", "composite.data.ranked-list");
      var items = args.items || [];
      if (items.length === 0) {
        root.appendChild(part("p", "rui-ranked-list__empty", args.empty));
        return root;
      }
      var list = document.createElement("ol");
      list.className = "rui-ranked-list__list";
      items.forEach(function (entry, index) {
        list.appendChild(item(entry, index, args));
      });
      root.appendChild(list);
      if (args.more > 0) {
        root.appendChild(part("p", "rui-ranked-list__more", args.more + " more not shown"));
      }
      return root;
    }
  };
})();
