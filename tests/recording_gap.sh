#!/bin/zsh
# Spuren synchron, auch wenn der Systemton erst später kommt (Tap liefert nur, solange etwas abspielt).
# Baut und installiert die App (app/build-app.sh) und nimmt zweimal auf (--gap-test): Systemton die ersten 2,5 s bzw.
# 30 s verworfen, danach spielt afplay leise einen Ton. Prüft: Spuren gleich lang, Ton an der richtigen Stelle, Mikrofon
# hört ihn höchstens 0,3 s später (Lautsprecher → Raum → Mikrofon; nur ohne Sprachverarbeitung messbar), Lücke genau einmal gefüllt. Braucht Mikrofon + Systemaudio.
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
  "$PY" - "$G" "$gap" "$fills" "$*" <<'PY'
import sys, numpy as np
g, gap, fills, vp = sys.argv[1], float(sys.argv[2]), int(sys.argv[3]), "--vp" in sys.argv[4]
mic, sys_ = (np.fromfile(f"{g}/t{i}.raw", dtype=np.float32) for i in (0, 1))
e = np.array([np.sqrt(np.mean(sys_[j:j + 160] ** 2)) for j in range(0, len(sys_) - 160, 160)])
onset = np.argmax(e > 1e-3) * 0.01 if (e > 1e-3).any() else None
s0 = int(gap * 16000); a, m = sys_[s0:s0 + 40000], mic[s0:s0 + 40000]
# Versatz über die Lautstärkekurve (10 ms), nicht über die Wellenform: der Testton ist tonal, die Wellenform-Korrelation
# hat viele fast gleich hohe Nebenspitzen. Gesucht wird nur in −0,5 … +1,0 s, gewertet nur, wenn das Mikrofon den Ton
# ≥ 10 dB über dem Rauschen hört und die Kurven klar ähnlich sind (r ≥ 0,5) – meist +19…+25 dB, r 0,8–0,9; bei +2 dB
# einmal r 0,58 und −0,12 s daneben.
# Mit Sprachverarbeitung nie: die Echounterdrückung nimmt den Ton aus dem Mikrofon (2026-10-31, 4 Läufe: −5 … +5 dB,
# Kurve verzerrt, Versatz zufällig +0,7/−0,5 s; früher −1,4 … +0,6 s) – das schwankende Ergebnis ließ den Test
# wechselnd scheitern. Ohne Sprachverarbeitung stabil +0,10 s.
logenv = lambda x: np.log(np.sqrt((x[:len(x) // 160 * 160].reshape(-1, 160) ** 2).mean(1)) + 1e-5)
ea, em = logenv(a), logenv(m)
def r_at(L):
    x, y = (ea[:len(ea) - L], em[L:]) if L >= 0 else (ea[-L:], em[:len(em) + L])
    n = min(len(x), len(y))
    with np.errstate(all="ignore"): r = np.corrcoef(x[:n], y[:n])[0, 1] if n > 10 else -1
    return -1 if np.isnan(r) else r      # Stille (konstante Kurve) → keine Aussage
lag, r = max(((L / 100, r_at(L)) for L in range(-50, 101)), key=lambda t: t[1])
db = lambda x: 10 * np.log10(np.mean(x ** 2) + 1e-12)
snr = db(m) - db(mic[max(s0 - 80000, 0):max(s0 - 16000, 1)])
heard = not vp and snr >= 10 and r >= 0.5
print(f"  Lücke {gap:g} s: Spuren {len(mic)/16000:.2f} / {len(sys_)/16000:.2f} s, Ton im Systemton ab {onset} s, "
      + (f"Mikrofon {lag:+.2f} s (r {r:.2f})" if heard else "Versatz nicht gemessen (" + ("Sprachverarbeitung" if vp else f"Mikrofon hört den Ton kaum, r {r:.2f}") + ")")
      + f", {fills}× gefüllt, Ton {snr:+.0f} dB")
ok = (abs(len(mic) - len(sys_)) < 0.8 * 16000 and onset is not None and onset >= gap - 0.5
      and (not heard or -0.02 <= lag <= 0.3) and fills == 1)
sys.exit(0 if ok else f"✗ Lücke {gap:g} s: Spuren nicht synchron")
PY
  local rc=$?; rm -rf "$G"; return $rc
}
run_case 2.5
run_case 30 --vp          # wie im Test 2026-10-10: lange Lücke, Sprachverarbeitung an (dort 49 s → 1 h Stille)
echo "✓ Spuren synchron trotz spät einsetzendem Systemton"
