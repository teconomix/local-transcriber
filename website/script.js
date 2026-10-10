// Kopier-Knopf für den Installationsbefehl. Ohne JavaScript bleibt der Knopf verborgen.
(function () {
  if (!navigator.clipboard) return;
  document.querySelectorAll(".copy-btn").forEach(function (btn) {
    var target = document.getElementById(btn.getAttribute("data-copy"));
    if (!target) return;
    var label = btn.querySelector("span");
    btn.hidden = false;
    btn.addEventListener("click", function () {
      navigator.clipboard.writeText(target.textContent.trim()).then(function () {
        label.textContent = "Kopiert";
        setTimeout(function () { label.textContent = "Kopieren"; }, 1800);
      });
    });
  });
})();
