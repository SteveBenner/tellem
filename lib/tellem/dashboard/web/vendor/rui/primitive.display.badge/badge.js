(function () {
  window.RUI = window.RUI || {};
  RUI.components = RUI.components || {};
  RUI.components["primitive.display.badge"] = {
    render: function (args) {
      var tone = args.tone || "neutral";
      var root = document.createElement("span");
      root.className = "rui-badge rui-badge--" + tone;
      root.setAttribute("data-rui-component", "primitive.display.badge");
      root.appendChild(document.createTextNode(args.text));
      if (tone !== "neutral") {
        var word = document.createElement("span");
        word.className = "rui-badge__tone";
        word.textContent = " " + tone;
        root.appendChild(word);
      }
      return root;
    }
  };
})();
