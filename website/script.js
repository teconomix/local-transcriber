// Kopier-Knopf für den Installationsbefehl. Ohne JavaScript bleibt der Knopf verborgen.
(function () {
  if (!navigator.clipboard) return;
  document.querySelectorAll(".copy-btn").forEach(function (btn) {
    var target = document.getElementById(btn.getAttribute("data-copy"));
    if (!target) return;
    var label = btn.querySelector("span");
    var idle = label.textContent;                               // Beschriftung kommt aus der Seite (de/en)
    var done = btn.getAttribute("data-copied") || "Kopiert";
    btn.hidden = false;
    btn.addEventListener("click", function () {
      navigator.clipboard.writeText(target.textContent.trim()).then(function () {
        label.textContent = done;
        setTimeout(function () { label.textContent = idle; }, 1800);
      });
    });
  });
})();
