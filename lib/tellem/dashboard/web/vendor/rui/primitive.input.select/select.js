(function () {
  window.RUI = window.RUI || {};
  RUI.components = RUI.components || {};
  RUI.components["primitive.input.select"] = {
    render: function (args, ctx) {
      var options = args.options || [];
      var hasAction = args.action !== null && args.action !== undefined;
      var chosen = -1;
      options.forEach(function (option, index) {
        if (option.value === args.value) chosen = index;
      });
      var active = -1;
      var isOpen = false;
      var typed = "";
      var typedTimer = null;

      var root = document.createElement("div");
      root.className = "rui-select";
      root.setAttribute("data-rui-component", "primitive.input.select");
      root.setAttribute("data-rui-name", args.name);
      root.setAttribute("data-rui-value", chosen >= 0 ? options[chosen].value : "");

      var labelId = ctx.uid("label");
      var buttonId = ctx.uid("button");
      var listId = ctx.uid("list");

      var label = document.createElement("span");
      label.className = "rui-select__label";
      label.id = labelId;
      label.textContent = args.label;

      var button = document.createElement("button");
      button.type = "button";
      button.className = "rui-select__button";
      button.id = buttonId;
      button.setAttribute("data-rui-control", "");
      button.setAttribute("role", "combobox");
      button.setAttribute("aria-haspopup", "listbox");
      button.setAttribute("aria-expanded", "false");
      button.setAttribute("aria-controls", listId);
      button.setAttribute("aria-labelledby", labelId + " " + buttonId);

      var shown = document.createElement("span");
      shown.className = "rui-select__shown";
      button.appendChild(shown);

      var list = document.createElement("ul");
      list.className = "rui-select__list";
      list.id = listId;
      list.setAttribute("role", "listbox");
      list.setAttribute("aria-labelledby", labelId);
      list.tabIndex = -1;
      list.hidden = true;

      var items = options.map(function (option, index) {
        var item = document.createElement("li");
        item.className = "rui-select__option";
        item.id = ctx.uid("option-" + index);
        item.setAttribute("role", "option");
        item.setAttribute("aria-selected", "false");
        item.textContent = option.label;
        item.addEventListener("click", function () {
          choose(index);
        });
        item.addEventListener("mousemove", function () {
          setActive(index);
        });
        list.appendChild(item);
        return item;
      });

      function paint() {
        shown.textContent = chosen >= 0 ? options[chosen].label : "Select";
        items.forEach(function (item, index) {
          item.setAttribute("aria-selected", index === chosen ? "true" : "false");
        });
      }

      function setActive(index) {
        active = index;
        items.forEach(function (item, position) {
          if (position === index) item.setAttribute("data-active", "true");
          else item.removeAttribute("data-active");
        });
        if (index >= 0 && items[index]) {
          button.setAttribute("aria-activedescendant", items[index].id);
          if (items[index].scrollIntoView) items[index].scrollIntoView({ block: "nearest" });
        } else {
          button.removeAttribute("aria-activedescendant");
        }
      }

      function onOutside(event) {
        if (!root.contains(event.target)) close();
      }

      function open() {
        if (isOpen || options.length === 0) return;
        isOpen = true;
        list.hidden = false;
        root.className = "rui-select rui-select--open";
        button.setAttribute("aria-expanded", "true");
        setActive(chosen >= 0 ? chosen : 0);
        document.addEventListener("pointerdown", onOutside, true);
      }

      function close() {
        if (!isOpen) return;
        isOpen = false;
        list.hidden = true;
        root.className = "rui-select";
        button.setAttribute("aria-expanded", "false");
        setActive(-1);
        document.removeEventListener("pointerdown", onOutside, true);
      }

      function choose(index) {
        chosen = index;
        root.setAttribute("data-rui-value", options[index].value);
        paint();
        close();
        button.focus();
        if (hasAction) {
          var values = {};
          values[args.name] = options[index].value;
          ctx.emit(args.action, values);
        }
      }

      function jump(character) {
        typed += character.toLowerCase();
        if (typedTimer) clearTimeout(typedTimer);
        typedTimer = setTimeout(function () {
          typed = "";
        }, 500);
        var start = active >= 0 ? active : 0;
        var search = typed.length === 1 ? 1 : 0;
        for (var step = 0; step < options.length; step++) {
          var index = (start + search + step) % options.length;
          if (options[index].label.toLowerCase().indexOf(typed) === 0) {
            if (!isOpen) open();
            setActive(index);
            return;
          }
        }
      }

      button.addEventListener("click", function () {
        if (isOpen) close();
        else open();
      });

      button.addEventListener("keyup", function (event) {
        if (event.key === " ") event.preventDefault();
      });

      button.addEventListener("keydown", function (event) {
        var key = event.key;
        if (event.ctrlKey || event.metaKey || event.altKey) return;
        if (key.length !== 1 || key === " ") typed = "";
        if (!isOpen) {
          if (key === "Enter" || key === " " || key === "ArrowDown" || key === "ArrowUp") {
            event.preventDefault();
            open();
          } else if (key.length === 1) {
            event.preventDefault();
            jump(key);
          }
          return;
        }
        if (key === "ArrowDown") {
          event.preventDefault();
          setActive(Math.min(active + 1, options.length - 1));
        } else if (key === "ArrowUp") {
          event.preventDefault();
          setActive(Math.max(active - 1, 0));
        } else if (key === "Home") {
          event.preventDefault();
          setActive(0);
        } else if (key === "End") {
          event.preventDefault();
          setActive(options.length - 1);
        } else if (key === "Enter" || key === " ") {
          event.preventDefault();
          if (active >= 0) choose(active);
        } else if (key === "Escape") {
          event.preventDefault();
          close();
        } else if (key === "Tab") {
          close();
        } else if (key.length === 1) {
          event.preventDefault();
          jump(key);
        }
      });

      list.addEventListener("mousedown", function (event) {
        event.preventDefault();
      });

      button.addEventListener("blur", function () {
        close();
      });

      paint();
      root.appendChild(label);
      root.appendChild(button);
      root.appendChild(list);
      return root;
    }
  };
})();
