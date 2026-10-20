#!/bin/zsh
# Spuren synchron, auch wenn der Systemton erst später kommt (Tap liefert nur, solange etwas abspielt).
# Baut und installiert die App (app/build-app.sh) und nimmt zweimal auf (--gap-test): Systemton die ersten 2,5 s bzw.
# 30 s verworfen, danach spielt afplay leise einen Ton. Prüft: Spuren gleich lang, Ton an der richtigen Stelle, Mikrofon
# hört ihn höchstens 0,3 s später (Lautsprecher → Raum → Mikrofon), Lücke genau einmal gefüllt. Braucht Mikrofon + Systemaudio.
set -euo pipefail
ROOT="${0:A:h:h}"
PY="${TRANSCRIBER_PY:-$HOME/.local/share/transcriber/venvs/app/bin/python}"
LOG=~/.local/share/transcriber/app.log
# Laufende Aufnahme = versteckte .m4a, die in der letzten Minute geschrieben wurde (alte Reste zählen nicht)
[[ -n $(find ~/Transcriber -name '.*.m4a' -mmin -1 2>/dev/null) ]] && { echo "✗ Es läuft gerade eine Aufnahme – Test übersprungen"; exit 1; }
"$ROOT/app/build-app.sh" >/dev/null 2>&1
run_case() {   # run_case LÜCKE [--vp]
  local gap=$1; shift
  local G; G=$(mktemp -d)
  local mark; mark=$(wc -l < $LOG)
  open -n ~/Applications/Transcriber.app --args --gap-test "$G" --gap "$gap" "$@"
  for i in $(seq 1 $(( ${gap%.*} + 30 ))); do grep -q "Gap-Test: fertig → $G" $LOG && break; sleep 1; done
  local f; f=$(find "$G" -name '[!.]*.m4a' | head -1)
  [[ -n "$f" ]] || { echo "✗ Lücke ${gap}s: keine Aufnahme entstanden"; rm -rf "$G"; return 1; }
  local fills; fills=$(tail -n +$((mark + 1)) $LOG | grep -c 'Stille in Systemton-Spur' || true)
  for i in 0 1; do ffmpeg -v error -y -i "$f" -map 0:a:$i -ac 1 -ar 16000 -f f32le "$G/t$i.raw"; done
  "$PY" - "$G" "$gap" "$fills" <<'PY'
import sys, numpy as np
g, gap, fills = sys.argv[1], float(sys.argv[2]), int(sys.argv[3])
mic, sys_ = (np.fromfile(f"{g}/t{i}.raw", dtype=np.float32) for i in (0, 1))
e = np.array([np.sqrt(np.mean(sys_[j:j + 160] ** 2)) for j in range(0, len(sys_) - 160, 160)])
onset = np.argmax(e > 1e-3) * 0.01 if (e > 1e-3).any() else None
s0 = int(gap * 16000); a, m = sys_[s0:s0 + 40000], mic[s0:s0 + 40000]
lag = (np.argmax(np.correlate(m - m.mean(), a - a.mean(), "full")) - (len(a) - 1)) / 16000
# Mit Sprachverarbeitung entfernt die Echounterdrückung den Testton fast ganz aus dem Mikrofon (2026-10-20: nur 7 dB
# über dem Rauschen, oft 0 dB) → Korrelation zufällig (−1,4 s). Ohne Sprachverarbeitung +8–9 dB, Versatz stabil ~0,1 s.
# Versatz daher nur prüfen, wenn das Mikrofon den Ton mindestens 5 dB über dem Rauschen hört.
db = lambda x: 10 * np.log10(np.mean(x ** 2) + 1e-12)
heard = db(m) - db(mic[max(s0 - 80000, 0):max(s0 - 16000, 1)]) >= 5
print(f"  Lücke {gap:g} s: Spuren {len(mic)/16000:.2f} / {len(sys_)/16000:.2f} s, Ton im Systemton ab {onset} s, "
      + (f"Mikrofon {lag:+.3f} s" if heard else "Versatz nicht messbar (Mikrofon hört den Ton kaum)") + f", {fills}× gefüllt, Ton +{db(m) - db(mic[max(s0 - 80000, 0):max(s0 - 16000, 1)]):.0f} dB")
ok = (abs(len(mic) - len(sys_)) < 0.8 * 16000 and onset is not None and onset >= gap - 0.5
      and (not heard or 0 <= lag <= 0.3) and fills == 1)
sys.exit(0 if ok else f"✗ Lücke {gap:g} s: Spuren nicht synchron")
PY
  local rc=$?; rm -rf "$G"; return $rc
}
run_case 2.5
run_case 30 --vp          # wie im Test 2026-10-10: lange Lücke, Sprachverarbeitung an (dort 49 s → 1 h Stille)
echo "✓ Spuren synchron trotz spät einsetzendem Systemton"
