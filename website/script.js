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

// Kampagnen-Kürzel (?k=…): wer über einen markierten Link kommt, bekommt es im Installationsbefehl mit
// (…/k/<kürzel>/install.sh – Pfad, weil zsh ein „?“ als Platzhalter liest), damit die Tageszählung Installationen
// der Quelle zuordnen kann. Nichts wird gespeichert.
(function () {
  var k = new URLSearchParams(location.search).get("k");
  if (!k || !/^[a-z0-9-]{1,24}$/.test(k)) return;
  document.querySelectorAll(".cmd pre").forEach(function (pre) {
    if (pre.textContent.indexOf("/k/") !== -1) return;          // Themenseiten haben ihr eigenes Kürzel
    pre.textContent = pre.textContent.replace(/\/install\.sh(?=\s|$)/, "/k/" + k + "/install.sh");
  });
  document.querySelectorAll('a[href^="../de/"], a[href^="../en/"], a[href^="./"], a[href="#installation"]').forEach(function (a) {
    var u = new URL(a.getAttribute("href"), location.href);
    if (u.origin !== location.origin || u.searchParams.has("k")) return;
    u.searchParams.set("k", k);
    a.setAttribute("href", u.pathname + u.search + u.hash);
  });
})();
