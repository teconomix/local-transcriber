#!/bin/bash
# Transcriber deinstallieren. Aufnahmen und Transkripte unter ~/Transcriber bleiben IMMER erhalten.
# Die Stimmdatenbank (biometrische Daten) und das Whisper-Modell werden nur nach Rückfrage gelöscht.
set -uo pipefail

DATA="$HOME/.local/share/transcriber"
# Meldungen auf Deutsch, wenn die erste bevorzugte macOS-Sprache Deutsch ist (sonst $LANG), ansonsten Englisch.
DE=0
_lang=$(defaults read -g AppleLanguages 2>/dev/null | awk 'NR==2' | tr -d ' ",') || _lang=""
if [[ "${_lang:-${LANG:-}}" == de* ]]; then DE=1; fi
t() { if [[ "$DE" == 1 ]]; then printf '%s' "$1"; else printf '%s' "$2"; fi; }   # t "deutsch" "english"
ask() {  # Frage über /dev/tty (read -p schrieb sie auf stderr → mit 2>/dev/null unsichtbar, bis 0.5.0)
    local a=""
    { printf '  %s %s ' "$1" "$(t '[j/N]' '[y/N]')" >/dev/tty && read -r a </dev/tty; } 2>/dev/null || return 1
    [[ "$a" =~ ^[jJyY] ]]
}

echo "$(t "Transcriber deinstallieren" "Uninstalling Transcriber")"
osascript -e 'quit app "Transcriber"' >/dev/null 2>&1 || true
plist="$HOME/Library/LaunchAgents/net.teconomix.transcriber.watch.plist"
[[ -f "$plist" ]] && { launchctl bootout "gui/$(id -u)" "$plist" 2>/dev/null; rm -f "$plist"; echo "  ✓ $(t "Ordnerwächter entfernt" "Folder watcher removed")"; }
rm -rf "$HOME/Applications/Transcriber.app" && echo "  ✓ $(t "App entfernt" "App removed")"
[[ -L "$HOME/.local/bin/transcriber" ]] && rm -f "$HOME/.local/bin/transcriber"

# Whisper-Modelle vor den Programmdaten: das Löschen braucht deren Python (huggingface_hub 2.x hält die Gewichte im
# gemeinsamen Speicher hub/blobs/, der Repo-Ordner enthält nur Verweise – rm -rf darauf gäbe keinen Platz frei).
for R in mlx-community/whisper-large-v3-turbo mlx-community/whisper-large-v3-turbo-8bit; do
    W="$HOME/.cache/huggingface/hub/models--${R//\//--}"
    if [[ -d "$W" ]] && ask "$(t "Whisper-Modell ${R#*/} (evtl. auch von anderen Programmen genutzt) löschen?" "Delete the Whisper model ${R#*/} (possibly also used by other programs)?")"; then
        if [[ -x "$DATA/venvs/app/bin/python" ]]; then
            "$DATA/venvs/app/bin/python" -I -c "import sys; from huggingface_hub import scan_cache_dir
i = scan_cache_dir()
[i.delete_revisions(*(v.commit_hash for v in r.revisions)).execute() for r in i.repos if r.repo_id == sys.argv[1]]" "$R" 2>/dev/null
        fi
        rm -rf "$W" && echo "  ✓ $(t "Whisper-Modell gelöscht" "Whisper model deleted")"
    fi
done

# Die Stimmdatenbank enthält biometrische Daten – sie wird nie verschoben oder kopiert: löschen oder liegen lassen.
if [[ -f "$DATA/speakers.db" ]] && ! ask "$(t "Stimmdatenbank (gelernte Stimmen) löschen?" "Delete the voice database (learned voices)?")"; then
    find "$DATA" -mindepth 1 -maxdepth 1 ! -name speakers.db -exec rm -rf {} +
    echo "  ✓ $(t "Programmdaten entfernt, Stimmdatenbank bleibt: $DATA/speakers.db" "Program data removed, voice database kept: $DATA/speakers.db")"
else
    rm -rf "$DATA" && echo "  ✓ $(t "Programmdaten und Stimmdatenbank entfernt ($DATA)" "Program data and voice database removed ($DATA)")"
fi

echo "$(t "Fertig. Deine Aufnahmen und Transkripte unter ~/Transcriber sind unverändert." "Done. Your recordings and transcripts in ~/Transcriber are unchanged.")"
echo "$(t "Freigaben in Systemeinstellungen › Datenschutz & Sicherheit kannst du dort selbst entfernen." "You can remove permissions yourself in System Settings › Privacy & Security.")"
