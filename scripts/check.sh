#!/bin/zsh
# Prüfungen vor jedem Release (ruft scripts/make-release.sh auf) und nach größeren Änderungen.
#   scripts/check.sh          schnell (~1 min, meist swift build): Kern-Tests, Skripte, Installer-Umbenennung, App, Export
#   scripts/check.sh --full   zusätzlich eine echte Transkription (macOS-Sprachausgabe → Whisper → pyannote, ~1 min)
#                             und eine 7-s-Aufnahme, ob Mikrofon und Systemton synchron liegen (installiert die App neu)
# Alles läuft in Wegwerf-Verzeichnissen; Stimmdatenbank, Transkripte und Einstellungen werden nicht berührt.
set -uo pipefail
cd "${0:A:h}/.."
REAL=~/.local/share/transcriber
PY="$REAL/venvs/app/bin/python"
FULL=0; [[ "${1:-}" == "--full" ]] && FULL=1
FAILED=()
step() { local label=$1; shift; print -P "%B▸ $label%b"
  if "$@"; then print -P "  %F{green}✓%f"; else print -P "  %F{red}✗ $label%f"; FAILED+=("$label"); fi; }

syntax() {
  local f ok=0
  for f in installer/*.sh; do bash -n "$f" || ok=1; done
  for f in scripts/*.sh app/*.sh website/deploy.sh tests/*.sh; do zsh -n "$f" || ok=1; done
  return $ok
}

export_check() {
  local d; d=$(mktemp -d); rmdir "$d"
  scripts/export-public.sh "$d" >/dev/null; local rc=$?
  rm -rf "$d"; return $rc
}

e2e() {
  local S; S=$(mktemp -d)
  mkdir -p "$S/data"
  [[ -d "$REAL/models" ]] && ln -s "$REAL/models" "$S/data/models"     # Sprechertrennung wie installiert
  say -v Anna -o "$S/probe.aiff" "Guten Tag. Das ist ein kurzer Test für den Transcriber. Wir prüfen heute die Spracherkennung." \
    || { rm -rf "$S"; return 1; }
  PATH="$REAL/bin:/opt/homebrew/bin:$PATH" TRANSCRIBER_DATA="$S/data" TRANSCRIBER_UI_LANG=en \
    "$REAL/venvs/app/bin/transcriber" transcribe "$S/probe.aiff" --language de --out "$S/out" >"$S/log" 2>&1
  local rc=$?
  if (( rc == 0 )); then
    "$PY" - "$S/out" <<'PY' || rc=1
import json, pathlib, sys
out = pathlib.Path(sys.argv[1])
doc = json.loads((out / "probe.transcript.json").read_text())
text = " ".join(w["w"] for w in doc["words"]).lower()
md = (out / "probe.md").read_text()
problems = [p for p, ok in [("Wörter fehlen", "test" in text and "spracherkennung" in text),
                            ("kein Sprecher", len(doc["speakers"]) >= 1),
                            ("Statuscode", all(c["status"] in {"sicher", "vermutlich", "unbekannt", "bestätigt"} for c in doc["speakers"])),
                            ("englischer Kopf", md.splitlines()[2].startswith("Source:"))] if not ok]
print("  erkannt:", text[:90])
sys.exit("  " + ", ".join(problems) if problems else 0)
PY
  else
    tail -5 "$S/log"
  fi
  rm -rf "$S"; return $rc
}

# Zwei Spuren, auf denen gleichzeitig gesprochen wird (Mikrofon + Call): beide Sätze müssen im Transkript stehen.
# In der Mischung allein schrieb Whisper nur eine Stimme mit (Videotest 2026-10-10).
e2e_overlap() {
  local S; S=$(mktemp -d)
  mkdir -p "$S/data"
  [[ -d "$REAL/models" ]] && ln -s "$REAL/models" "$S/data/models"
  say -v Anna -o "$S/a.aiff" "Ich erzähle gerade vom Wochenende in den Bergen. Wir sind auf den Gipfel gewandert und hatten herrliches Wetter." &&
  say -v "Eddy (Deutsch (Deutschland))" -o "$S/b.aiff" "Die Quartalszahlen liegen vor. Der Umsatz ist gestiegen, die Kosten sind gesunken." &&
  ffmpeg -v error -y -i "$S/a.aiff" -i "$S/b.aiff" -filter_complex "[0:a]aresample=48000,apad=pad_dur=3[a];[1:a]aresample=48000,adelay=2500,apad=pad_dur=1[b]" \
    -map "[a]" -map "[b]" -c:a aac -b:a 96k -ac 1 -shortest "$S/call.m4a" || { rm -rf "$S"; return 1; }
  PATH="$REAL/bin:/opt/homebrew/bin:$PATH" TRANSCRIBER_DATA="$S/data" TRANSCRIBER_UI_LANG=de \
    "$REAL/venvs/app/bin/transcriber" transcribe "$S/call.m4a" --language de --out "$S/out" >"$S/log" 2>&1
  local rc=$?
  if (( rc == 0 )); then
    "$PY" - "$S/out/call.transcript.json" <<'PY' || rc=1
import json, sys
d = json.load(open(sys.argv[1]))
text = " ".join(w["w"] for w in d["words"]).lower()
need = ["wochenende", "gipfel", "wetter", "quartalszahlen", "umsatz", "kosten"]
miss = [w for w in need if w not in text]
print(f"  Modus {d['track_mode']}, Überlappung {d['timing_s'].get('overlap_s', 0)} s, fehlend: {miss or '–'}")
sys.exit("  beide Stimmen erwartet" if miss or d["track_mode"] != "getrennt" else 0)
PY
  else
    tail -5 "$S/log"
  fi
  rm -rf "$S"; return $rc
}

step "Kern-Tests (Python)"                 "$PY" -m unittest -q tests.test_core
step "Syntax der Skripte"                  syntax
step "Installer: ~/Transkription → ~/Transcriber" tests/installer_migration.sh
step "Installer: Rückfragen sichtbar bei curl | bash" tests/installer_prompt.sh
step "App: Übersetzungen vollständig (baut die App)" app/l10n-check.sh
step "App: Versionsvergleich Update-Hinweis" tests/update_version.sh
step "Export fürs öffentliche Repo (Namens-/Pfadprüfung)" export_check
(( FULL )) && step "Ende-zu-Ende: echte Transkription" e2e
(( FULL )) && step "Ende-zu-Ende: zwei Spuren sprechen gleichzeitig" e2e_overlap
(( FULL )) && step "Aufnahme: Spuren synchron (baut + installiert die App, spielt leise einen Ton)" tests/recording_gap.sh

if (( ${#FAILED} )); then print -P "\n%F{red}✗ Fehlgeschlagen:%f ${(j:, :)FAILED}"; exit 1; fi
print -P "\n%F{green}✓ Alle Prüfungen bestanden%f"
