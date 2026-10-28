#!/bin/zsh
# Öffentliche Fassung fürs GitHub-Repo erzeugen: kuratierte Dateien in ein frisches Verzeichnis mit eigenem,
# neuem Git-Verlauf (der interne Verlauf enthält Notizen mit Namen und Homelab-Details und wird NICHT mitgenommen).
#   scripts/export-public.sh [ZIEL]     (Standard: ../transcriber-public)
# Danach prüfen, dann: cd ZIEL && git remote add origin https://github.com/teconomix/local-transcriber.git && git push -u origin main
set -euo pipefail
cd "${0:A:h}/.."
DEST="${1:-../transcriber-public}"
[[ -e "$DEST" ]] && { echo "$DEST existiert schon – bitte vorher entfernen oder anderes Ziel angeben"; exit 1; }

# Was hinein darf (alles andere bleibt draußen: CLAUDE.md, .mcp.json, bench/, dist/, …)
KEEP=(README.md LICENSE THIRD_PARTY_NOTICES.md VERSION pyproject.toml .gitignore
      transcriber app/Package.swift app/build-app.sh app/l10n-check.sh app/make-icon.sh app/Resources app/Sources
      installer scripts/make-release.sh scripts/install-watch.sh scripts/net.teconomix.transcriber.watch.plist
      scripts/export-public.sh scripts/check.sh tests docs website)

mkdir -p "$DEST"
for p in $KEEP; do
  git ls-files -z -- "$p" | while IFS= read -r -d '' f; do mkdir -p "$DEST/${f:h}"; cp -p "$f" "$DEST/$f"; done
done

# Nur für den Betreiber: Übergabenotiz, Veröffentlichungs-Checkliste (Uberspace-/Cloudflare-Details), Deploy-Skript
rm -f "$DEST/docs/STAND.md" "$DEST/docs/VEROEFFENTLICHUNG.md" "$DEST/docs/TESTPLAN.md" "$DEST/website/deploy.sh"

# Letzte Kontrolle: keine Namen von Personen aus der lokalen Stimmdatenbank, keine Wörter der lokalen Sperrliste
# (~/.local/share/transcriber/publish-blocklist.txt, eine Zeile je Begriff – liegt bewusst NICHT im Repo),
# keine internen Hosts/Adressen, keine absoluten Home-Pfade.
# Namen zählen als ganzes Wort in gleicher Schreibweise (sonst schlug der Nachname „Lang“ bei „language“ an).
# Namensteile, die zugleich harmlose Wörter sind (z. B. „Anna“ = macOS-Stimme in check.sh), stehen in
# ~/.local/share/transcriber/publish-allowlist.txt – ebenfalls nicht im Repo.
BAD='\.lan\b|192\.168\.|10\.0\.|vaultwarden|/Users/[a-z]'
NAMES=''
DB=~/.local/share/transcriber/speakers.db
OWNER=$(grep -m1 -i 'copyright' LICENSE | sed 's/.*[0-9]\{4\} //')     # Urheber darf genannt werden
AL=~/.local/share/transcriber/publish-allowlist.txt
ALLOW=" $(grep -v '^#' "$AL" 2>/dev/null | tr '\n' ' ' || true) "    # fehlt die Datei: leer (vorher brach set -e still ab)
if [[ -f $DB ]]; then
  for w in ${(f)"$(sqlite3 -readonly "$DB" 'SELECT name FROM persons' | tr ' ' '\n' | awk 'length >= 4')"}; do
    [[ " $OWNER " == *" $w "* || $ALLOW == *" $w "* ]] || NAMES+="${NAMES:+|}$w"
  done
fi
BL=~/.local/share/transcriber/publish-blocklist.txt
[[ -f $BL ]] || echo "Hinweis: keine Sperrliste $BL – geprüft werden nur Namen aus der Stimmdatenbank" >&2
[[ -f $BL ]] && for w in ${(f)"$(grep -v '^#' "$BL" | sed '/^$/d')"}; do BAD+="|$w"; done
hits=0
grep -r -n -i -E "$BAD" "$DEST" --exclude=LICENSE --exclude=export-public.sh && hits=1
[[ -n $NAMES ]] && grep -r -n -I -w -E "$NAMES" "$DEST" --exclude=LICENSE --exclude=export-public.sh && hits=1
if (( hits )); then
  echo "\n✗ Obige Treffer vor der Veröffentlichung entfernen (Export liegt in $DEST)."; exit 1
fi
grep -rn --exclude=export-public.sh "\[GITHUB-NUTZER\]" "$DEST" >/dev/null && echo "! Platzhalter [GITHUB-NUTZER] in website/ noch ersetzen."

(cd "$DEST" && git init -q -b main && git add -A && git commit -q -m "Transcriber $(cat VERSION) – first public version")
echo "✓ $DEST: $(cd "$DEST" && git ls-files | wc -l | tr -d ' ') Dateien, ein Commit."
