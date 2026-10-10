#!/bin/bash
# Transcriber deinstallieren. Aufnahmen und Transkripte unter ~/Transkription bleiben IMMER erhalten.
# Die Stimmdatenbank (biometrische Daten) und das Whisper-Modell werden nur nach Rückfrage gelöscht.
set -uo pipefail

DATA="$HOME/.local/share/transcriber"
ask() { local a; read -r -p "  $1 [j/N] " a </dev/tty 2>/dev/null || return 1; [[ "$a" =~ ^[jJyY] ]]; }

echo "Transcriber deinstallieren"
osascript -e 'quit app "Transcriber"' >/dev/null 2>&1 || true
plist="$HOME/Library/LaunchAgents/net.teconomix.transcriber.watch.plist"
[[ -f "$plist" ]] && { launchctl bootout "gui/$(id -u)" "$plist" 2>/dev/null; rm -f "$plist"; echo "  ✓ Ordnerwächter entfernt"; }
rm -rf "$HOME/Applications/Transcriber.app" && echo "  ✓ App entfernt"
[[ -L "$HOME/.local/bin/transcriber" ]] && rm -f "$HOME/.local/bin/transcriber"

# Die Stimmdatenbank enthält biometrische Daten – sie wird nie verschoben oder kopiert: löschen oder liegen lassen.
if [[ -f "$DATA/speakers.db" ]] && ! ask "Stimmdatenbank (gelernte Stimmen) löschen?"; then
    find "$DATA" -mindepth 1 -maxdepth 1 ! -name speakers.db -exec rm -rf {} +
    echo "  ✓ Programmdaten entfernt, Stimmdatenbank bleibt: $DATA/speakers.db"
else
    rm -rf "$DATA" && echo "  ✓ Programmdaten und Stimmdatenbank entfernt ($DATA)"
fi

W="$HOME/.cache/huggingface/hub/models--mlx-community--whisper-large-v3-turbo"
if [[ -d "$W" ]] && ask "Whisper-Modell (~3 GB, evtl. auch von anderen Programmen genutzt) löschen?"; then
    rm -rf "$W" && echo "  ✓ Whisper-Modell gelöscht"
fi
echo "Fertig. Deine Aufnahmen und Transkripte unter ~/Transkription sind unverändert."
echo "Freigaben in Systemeinstellungen › Datenschutz & Sicherheit kannst du dort selbst entfernen."
