#!/bin/zsh
# Rückfragen von Installer und Deinstaller müssen bei `curl … | bash` sichtbar sein und die Antwort lesen.
# (0.5.0: read -p schrieb die Frage auf stderr, das auf /dev/null umgeleitet war → Installer schien zu hängen.)
# Läuft in einem Pseudo-Terminal (script), stdin des Skripts ist wie bei curl | bash eine Pipe.
set -euo pipefail
ROOT="${0:A:h:h}"
S=$(mktemp -d); trap "rm -rf '$S'" EXIT
for f in install uninstall; do
  { sed -n '/^t() *{/,/^}/p;/^t() *{.*}/p' "$ROOT/installer/$f.sh" | head -1
    sed -n '/^ask() *{/,/^}/p' "$ROOT/installer/$f.sh"
    print -r -- 'DE=1; YES=0; if ask "Testfrage?"; then echo "ANTWORT=ja"; else echo "ANTWORT=nein"; fi'
  } > "$S/$f.sh"
  grep -q '^ask()' "$S/$f.sh" || { echo "✗ $f.sh: ask() nicht gefunden"; exit 1; }
  (sleep 1; print j; sleep 1) | script -q "$S/$f.out" bash -c "cat '$S/$f.sh' | bash" >/dev/null
  out=$(tr '\r' '\n' < "$S/$f.out")
  [[ "$out" == *"Testfrage? [j/N]"* ]] || { echo "✗ $f.sh: Frage nicht sichtbar"; print -r -- "$out"; exit 1; }
  [[ "$out" == *"ANTWORT=ja"* ]] || { echo "✗ $f.sh: Antwort nicht gelesen"; print -r -- "$out"; exit 1; }
done
echo "✓ Rückfragen sichtbar (Installer, Deinstaller)"
