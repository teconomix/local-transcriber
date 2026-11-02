#!/bin/zsh
# Homebrew startet das uninstall-Skript in einer eigenen Prozessgruppe: Es darf dort nicht an /dev/tty hängen (bis 0.13:
# Zustand T, `brew upgrade` stand für immer, App schon gelöscht) und keine Daten löschen; der Wächter kommt zurück.
# Läuft an einem echten Pseudo-Terminal, Prozess im Hintergrund wie bei Homebrew (SystemCommand: pgroup: true).
set -euo pipefail
ROOT="${0:A:h:h}"
S=$(mktemp -d); trap "rm -rf '$S'" EXIT
mkdir -p "$S/bin" "$S/home/.local/share/transcriber/venvs" "$S/home/Applications/Transcriber.app" "$S/home/Library/LaunchAgents" \
  "$S/home/.cache/huggingface/hub/models--mlx-community--whisper-large-v3-turbo-8bit"
for c in osascript launchctl; do print '#!/bin/sh\nexit 0' > "$S/bin/$c"; chmod +x "$S/bin/$c"; done   # echte App, echter Wächter bleiben
D="$S/home/.local/share/transcriber"; print x > "$D/speakers.db"; print x > "$D/config.json"
P="$S/home/Library/LaunchAgents/net.teconomix.transcriber.watch.plist"; print x > "$P"
HOME="$S/home" PATH="$S/bin:$PATH" /usr/bin/python3 -I - "$ROOT/installer/uninstall.sh" <<'PY'
import os, pty, select, signal, subprocess, sys, time
pid, fd = pty.fork()
if pid == 0:                                 # Sitzungsführer wie brew; Skript in eigener Prozessgruppe, also Hintergrund
    p = subprocess.Popen(["/bin/bash", sys.argv[1]], stdin=subprocess.PIPE, preexec_fn=os.setpgrp)
    p.stdin.close(); os._exit(p.wait())
end = time.time() + 20; st = None
while time.time() < end:
    if select.select([fd], [], [], 0.2)[0]:
        try: os.read(fd, 4096)
        except OSError: pass
    done, code = os.waitpid(pid, os.WNOHANG)
    if done: st = os.waitstatus_to_exitcode(code); break
if st != 0:
    if st is None: os.kill(pid, signal.SIGKILL)
    subprocess.run(["pkill", "-9", "-f", sys.argv[1]])
    sys.exit(f"✗ uninstall.sh hängt oder scheitert im Hintergrund (Status {st})")
PY
[[ ! -e "$S/home/Applications/Transcriber.app" ]] || { echo "✗ App nicht entfernt"; exit 1; }
[[ -f "$D/speakers.db" && -f "$D/config.json" && -d "$D/venvs" ]] || { echo "✗ Daten gelöscht"; exit 1; }
[[ -d "$S/home/.cache/huggingface/hub/models--mlx-community--whisper-large-v3-turbo-8bit" ]] || { echo "✗ Modell gelöscht"; exit 1; }
[[ -f "$D/watch.plist.saved" && ! -e "$P" ]] || { echo "✗ Wächter nicht beiseitegelegt"; exit 1; }
grep -q 'watch.plist.saved' "$ROOT/installer/install.sh" || { echo "✗ install.sh setzt den Wächter nicht wieder ein"; exit 1; }
echo "✓ Deinstaller unter Homebrew: hängt nicht, Daten bleiben, Wächter beiseitegelegt"
