#!/bin/bash
# Transcriber – Installer für macOS (Apple Silicon).
#
#   curl -fsSL https://transcriber.teconomix.net/install.sh | bash
#
# Installiert in das Benutzerkonto, ohne Administratorrechte:
#   ~/Applications/Transcriber.app           Menüleisten-App
#   ~/.local/share/transcriber/               Python-Umgebung, Modelle, Stimmdatenbank, Protokolle
#   ~/.local/bin/transcriber                  Kommandozeile
#   ~/Transkription/                          Aufnahmen und Transkripte
# Lädt aus dem Internet: die Release-Dateien (dieser Server), uv + Python (astral.sh), Python-Pakete (PyPI),
# das Whisper-Modell (Hugging Face, ~3 GB) und – falls nicht vorhanden – ffmpeg (ffmpeg.martin-riedl.de).
# Jede Datei von diesem Server wird gegen SHA256SUMS geprüft. Erneut ausführen = aktualisieren.
#
# Optionen: --no-launch (App nicht starten), --no-watch (Ordnerwächter nicht anbieten), --yes (keine Rückfragen)

set -euo pipefail

VERSION="__VERSION__"
BASE="${TRANSCRIBER_BASE:-__BASE__}"
DATA="$HOME/.local/share/transcriber"
APPS="$HOME/Applications"
WHISPER="mlx-community/whisper-large-v3-turbo"

say()  { printf '\033[1m▸ %s\033[0m\n' "$*"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }
die()  { printf '\n\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
# Meldungen auf Deutsch, wenn die erste bevorzugte macOS-Sprache Deutsch ist (sonst $LANG), ansonsten Englisch.
DE=0
_lang=$(defaults read -g AppleLanguages 2>/dev/null | awk 'NR==2' | tr -d ' ",') || _lang=""
if [[ "${_lang:-${LANG:-}}" == de* ]]; then DE=1; fi
t()    { if [[ "$DE" == 1 ]]; then printf '%s' "$1"; else printf '%s' "$2"; fi; }   # t "deutsch" "english"
ask()  {  # ask "Frage" → 0 bei ja. Bei curl | bash ist stdin die Pipe: Frage und Antwort laufen über /dev/tty.
    [[ "$YES" == 1 ]] && return 0      # (read -p schrieb die Frage auf stderr → mit 2>/dev/null unsichtbar, 0.5.0)
    local a=""
    { printf '  %s %s ' "$1" "$(t '[j/N]' '[y/N]')" >/dev/tty && read -r a </dev/tty; } 2>/dev/null || return 1
    [[ "$a" =~ ^[jJyY] ]]
}
busy() {  # busy "Text" befehl …: Ausgabe ins Protokoll; solange er läuft, Drehrad + Laufzeit. Bei Fehler: Protokollende.
    local msg=$1; shift
    local log; log=$(mktemp)
    "$@" >"$log" 2>&1 &
    local pid=$! i=0 t0=$SECONDS rc=0 s
    local frames=('|' '/' '-' '\')
    if [[ -t 1 ]]; then
        while kill -0 "$pid" 2>/dev/null; do
            s=$((SECONDS - t0))
            printf '\r  %s %s  %d:%02d ' "${frames[i]}" "$msg" $((s / 60)) $((s % 60))
            i=$(((i + 1) % 4)); sleep 0.2
        done
        printf '\r\033[K'
    fi
    wait "$pid" || rc=$?
    if [[ $rc -ne 0 ]]; then tail -15 "$log" >&2; fi
    rm -f "$log"; return $rc
}

main() {
    LAUNCH=1; WATCH=1; YES=0
    for a in "$@"; do case "$a" in
        --no-launch) LAUNCH=0 ;; --no-watch) WATCH=0 ;; --yes) YES=1 ;;
        *) die "$(t "unbekannte Option: $a" "unknown option: $a")" ;; esac; done

    printf '\n\033[1mTranscriber %s – Installation\033[0m\n\n' "$VERSION"

    # 1. Voraussetzungen ------------------------------------------------------------------------
    say "$(t "Voraussetzungen prüfen" "Checking requirements")"
    [[ "$(uname -s)" == Darwin ]] || die "$(t "Nur für macOS." "macOS only.")"
    [[ "$(uname -m)" == arm64 ]] || die "$(t "Nur für Macs mit Apple Silicon (M1 oder neuer) – die Spracherkennung nutzt MLX." "Apple Silicon Macs only (M1 or newer) – speech recognition uses MLX.")"
    [[ $EUID -ne 0 ]] || die "$(t "Bitte nicht mit sudo ausführen – installiert wird ins eigene Benutzerkonto." "Please do not run with sudo – it installs into your own user account.")"
    local mac; mac=$(sw_vers -productVersion)
    [[ "${mac%%.*}" -ge 14 ]] || die "$(t "macOS 14 Sonoma oder neuer nötig (gefunden: $mac)." "macOS 14 Sonoma or newer required (found: $mac).")"
    [[ "${mac%%.*}" -ge 26 ]] || warn "$(t "macOS $mac: KI-Funktionen (Diktat aufräumen, Dateinamen) brauchen macOS 26 mit Apple Intelligence." "macOS $mac: AI features (dictation cleanup, file names) require macOS 26 with Apple Intelligence.")"
    local free; free=$(df -g "$HOME" | awk 'NR==2 {print $4}')
    [[ "$free" -ge 8 ]] || die "$(t "Zu wenig Speicherplatz: $free GB frei, nötig sind etwa 8 GB." "Not enough disk space: $free GB free, about 8 GB needed.")"
    ok "$(t "macOS $mac, Apple Silicon, $free GB frei" "macOS $mac, Apple Silicon, $free GB free")"

    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT   # Wert jetzt einsetzen: der Hook läuft nach dem Ende von main
    mkdir -p "$DATA/bin" "$DATA/models" "$APPS" "$HOME/.local/bin"

    # 2. Release-Dateien ------------------------------------------------------------------------
    say "$(t "Transcriber $VERSION laden" "Downloading Transcriber $VERSION")"
    local rel="$BASE/download/$VERSION"
    for f in SHA256SUMS "Transcriber-$VERSION.zip" "transcriber-$VERSION.tar.gz" "pyannote-community-1.tar.gz" uninstall.sh; do
        curl -fsSL --retry 3 -o "$tmp/$f" "$rel/$f" || die "$(t "Download fehlgeschlagen: $rel/$f" "Download failed: $rel/$f")"
    done
    (cd "$tmp" && shasum -a 256 -c SHA256SUMS --quiet) || die "$(t "Prüfsumme stimmt nicht – Download beschädigt oder manipuliert." "Checksum mismatch – download corrupted or tampered with.")"
    ok "$(t "Prüfsummen stimmen" "Checksums verified")"

    # 3. Python-Umgebung --------------------------------------------------------------------------
    say "$(t "Python-Umgebung einrichten (uv, Python 3.12, Pakete – dauert ein paar Minuten)" "Setting up Python environment (uv, Python 3.12, packages – takes a few minutes)")"
    local uv="$DATA/bin/uv"
    if [[ ! -x "$uv" ]]; then
        # Ausgabe ins Protokoll: der uv-Installer warnt sonst rot, wenn ein anderes uv im PATH liegt (Homebrew) – hier egal,
        # weil immer $DATA/bin/uv aufgerufen wird.
        busy "$(t "uv laden" "Downloading uv")" sh -c 'curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR="$1" UV_NO_MODIFY_PATH=1 sh' _ "$DATA/bin" \
            || die "$(t "uv konnte nicht installiert werden." "Could not install uv.")"
    fi
    busy "$(t "Python 3.12" "Python 3.12")" "$uv" venv --allow-existing --python 3.12 "$DATA/venvs/app" || die "$(t "Python-Umgebung konnte nicht angelegt werden." "Could not create the Python environment.")"
    busy "$(t "Pakete laden und installieren (rund 1 GB)" "Downloading and installing packages (about 1 GB)")" \
        "$uv" pip install --python "$DATA/venvs/app/bin/python" "$tmp/transcriber-$VERSION.tar.gz" \
        || die "$(t "Python-Pakete konnten nicht installiert werden." "Could not install the Python packages.")"
    # uv endet bei Netzfehlern gelegentlich mit Status 0 und unvollständiger Umgebung – deshalb Importe prüfen.
    "$DATA/venvs/app/bin/python" -c "import mlx_whisper, pyannote.audio, transcriber.pipeline" 2>/dev/null \
        || die "$(t "Python-Pakete unvollständig – bitte den Installer erneut ausführen." "Python packages incomplete – please run the installer again.")"
    ln -sf "$DATA/venvs/app/bin/transcriber" "$HOME/.local/bin/transcriber"
    ok "$(t "Python-Umgebung bereit" "Python environment ready")"

    # 4. ffmpeg -----------------------------------------------------------------------------------
    say "ffmpeg"
    if [[ -x "$DATA/bin/ffmpeg" && -x "$DATA/bin/ffprobe" ]] || { command -v ffmpeg && command -v ffprobe; } >/dev/null 2>&1; then
        ok "$(t "vorhanden" "already present")"
    else
        for t in ffmpeg ffprobe; do
            # Statischer Apple-Silicon-Build; Prüfsumme liegt neben der Datei (Redirect auf die aktuelle Version).
            # Die Weiterleitung liefert gelegentlich kurz 404 (beobachtet 2026-10-10) – bis zu dreimal versuchen.
            local url="" n
            for n in 1 2 3; do
                url=$(curl -fsSLI -o /dev/null -w '%{url_effective}' \
                    "https://ffmpeg.martin-riedl.de/redirect/latest/macos/arm64/release/$t.zip" 2>/dev/null) && break
                url=""; sleep 3
            done
            [[ -n "$url" ]] || die "$(t "ffmpeg: Download-Adresse nicht erreichbar (ffmpeg.martin-riedl.de). Alternativ: brew install ffmpeg" "ffmpeg: download address not reachable (ffmpeg.martin-riedl.de). Alternatively: brew install ffmpeg")"
            curl -fsSL --retry 3 -o "$tmp/$t.zip" "$url" && curl -fsSL -o "$tmp/$t.zip.sha256" "$url.sha256" \
                || die "$(t "ffmpeg: Download fehlgeschlagen." "ffmpeg: download failed.")"
            [[ "$(shasum -a 256 "$tmp/$t.zip" | cut -d' ' -f1)" == "$(cut -d' ' -f1 "$tmp/$t.zip.sha256")" ]] \
                || die "$(t "ffmpeg: Prüfsumme stimmt nicht." "ffmpeg: checksum mismatch.")"
            unzip -oq "$tmp/$t.zip" -d "$DATA/bin" && chmod +x "$DATA/bin/$t"
            "$DATA/bin/$t" -version >/dev/null 2>&1 || die "$(t "$t lässt sich nicht starten." "$t cannot be started.")"
        done
        ok "$(t "ffmpeg installiert (statischer Build)" "ffmpeg installed (static build)")"
    fi

    # 5. Modelle ----------------------------------------------------------------------------------
    say "$(t "Modelle" "Models")"
    rm -rf "$DATA/models/speaker-diarization-community-1"
    tar -xzf "$tmp/pyannote-community-1.tar.gz" -C "$DATA/models"
    ok "$(t "Sprechererkennung" "Speaker recognition") (pyannote community-1, CC-BY-4.0)"
    say "$(t "Spracherkennungsmodell laden (Whisper large-v3-turbo, ~3 GB – kann dauern)" "Downloading speech recognition model (Whisper large-v3-turbo, ~3 GB – may take a while)")"
    # Über Python statt `hf download`: ohne Werbe-Hinweis der CLI und ohne Token-Warnung des Servers, Balken bleibt
    "$DATA/venvs/app/bin/python" -c "import sys; from huggingface_hub import snapshot_download, logging as l
l.set_verbosity_error(); snapshot_download(sys.argv[1])" "$WHISPER" >/dev/null || die "$(t "Whisper-Modell konnte nicht geladen werden (Hugging Face erreichbar?)." "Could not download the Whisper model (is Hugging Face reachable?).")"
    ok "Whisper large-v3-turbo"

    # 6. App ----------------------------------------------------------------------------------------
    say "$(t "App installieren" "Installing the app")"
    osascript -e 'quit app "Transcriber"' >/dev/null 2>&1 || true
    sleep 1
    rm -rf "$APPS/Transcriber.app"
    ditto -x -k "$tmp/Transcriber-$VERSION.zip" "$APPS"
    xattr -dr com.apple.quarantine "$APPS/Transcriber.app" 2>/dev/null || true
    # Bis 0.5 hieß der Datenordner ~/Transkription → einmalig umbenennen (gleiches Laufwerk, nichts wird kopiert).
    # App ist beendet; der Wächter wird angehalten und in Schritt 7 neu gestartet. Pfade in der Stimmdatenbank mitziehen.
    if [[ -d "$HOME/Transkription" && ! -e "$HOME/Transcriber" ]]; then
        launchctl bootout "gui/$(id -u)" "$HOME/Library/LaunchAgents/net.teconomix.transcriber.watch.plist" 2>/dev/null || true
        mv "$HOME/Transkription" "$HOME/Transcriber" || die "$(t "~/Transkription konnte nicht in ~/Transcriber umbenannt werden." "Could not rename ~/Transkription to ~/Transcriber.")"
        if [[ -f "$DATA/speakers.db" ]]; then "$DATA/venvs/app/bin/python" -c "import sqlite3, sys
db = sqlite3.connect(sys.argv[1]); old, new = sys.argv[2] + '/', sys.argv[3] + '/'
for tab, cols in (('embeddings', ('source',)), ('jobs', ('source', 'transcript'))):
    for c in cols:
        db.execute(f'UPDATE {tab} SET {c} = ? || substr({c}, ?) WHERE substr({c}, 1, ?) = ?', (new, len(old) + 1, len(old), old))
db.commit()" "$DATA/speakers.db" "$HOME/Transkription" "$HOME/Transcriber" || warn "$(t "Pfade in der Stimmdatenbank nicht angepasst (unkritisch)." "Paths in the voice database not updated (harmless).")"; fi
        # Statusdateien (Liste „Transkriptionen“ im Panel) zeigen sonst ins Leere
        "$DATA/venvs/app/bin/python" -c "import json, pathlib, sys
old, new = sys.argv[2] + '/', sys.argv[3] + '/'
fix = lambda v: new + v[len(old):] if isinstance(v, str) and v.startswith(old) else {k: fix(x) for k, x in v.items()} if isinstance(v, dict) else v
for f in pathlib.Path(sys.argv[1]).glob('*.json'):
    try: f.write_text(json.dumps(fix(json.loads(f.read_text())), ensure_ascii=False))
    except Exception: pass" "$DATA/jobs" "$HOME/Transkription" "$HOME/Transcriber" || true
        ok "$(t "Ordner ~/Transkription heißt jetzt ~/Transcriber" "Folder ~/Transkription is now ~/Transcriber")"
    fi
    mkdir -p "$HOME/Transcriber"
    cp "$tmp/uninstall.sh" "$DATA/uninstall.sh"; chmod +x "$DATA/uninstall.sh"
    ok "$APPS/Transcriber.app"

    # 7. Ordnerwächter (optional) -----------------------------------------------------------------
    local plist="$HOME/Library/LaunchAgents/net.teconomix.transcriber.watch.plist"
    if [[ -f "$plist" ]]; then
        launchctl bootout "gui/$(id -u)" "$plist" 2>/dev/null || true
        launchctl bootstrap "gui/$(id -u)" "$plist" && ok "$(t "Ordnerwächter neu gestartet" "Folder watcher restarted")"
    elif [[ "$WATCH" == 1 ]] && ask "$(t "Ordner ~/Transcriber überwachen (abgelegte Audiodateien automatisch transkribieren)?" "Watch the folder ~/Transcriber (automatically transcribe audio files dropped there)?")"; then
        mkdir -p "$HOME/Library/LaunchAgents"
        cat >"$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>net.teconomix.transcriber.watch</string>
  <key>ProgramArguments</key><array><string>$DATA/venvs/app/bin/transcriber</string><string>watch</string></array>
  <key>EnvironmentVariables</key><dict>
    <key>PATH</key><string>$DATA/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    <key>HOME</key><string>$HOME</string><key>PYTHONUNBUFFERED</key><string>1</string></dict>
  <key>RunAtLoad</key><true/><key>KeepAlive</key><true/><key>ProcessType</key><string>Background</string>
  <key>StandardOutPath</key><string>$DATA/watch.log</string><key>StandardErrorPath</key><string>$DATA/watch.log</string>
</dict></plist>
PLIST
        launchctl bootstrap "gui/$(id -u)" "$plist" && ok "$(t "Ordnerwächter läuft" "Folder watcher running")"
    fi

    # 8. Fertig -------------------------------------------------------------------------------------
    if [[ "$DE" == 1 ]]; then
    printf '\n\033[1;32mFertig.\033[0m Transcriber %s ist installiert.\n\n' "$VERSION"
    cat <<'TXT'
  Beim ersten Aufnehmen fragt macOS nach Mikrofon und Systemaudio – bitte erlauben.
  Diktat (Taste halten, sprechen, loslassen): in den Einstellungen einschalten; dafür braucht es
  die Freigabe „Bedienungshilfen“. Kalender-Termine als Dateinamen: Freigabe „Kalender“.

  Kommandozeile: ~/.local/bin/transcriber  (ggf. ~/.local/bin zum PATH hinzufügen)
  Deinstallieren: bash ~/.local/share/transcriber/uninstall.sh
TXT
    else
    printf '\n\033[1;32mDone.\033[0m Transcriber %s is installed.\n\n' "$VERSION"
    cat <<'TXT'
  The first time you record, macOS asks for Microphone and System Audio Recording access – please allow.
  Dictation (hold a key, speak, release): turn it on in Settings; it needs the
  "Accessibility" permission. Calendar events as file names: "Calendars" permission.

  Command line: ~/.local/bin/transcriber  (add ~/.local/bin to your PATH if needed)
  Uninstall: bash ~/.local/share/transcriber/uninstall.sh
TXT
    fi
    [[ "$LAUNCH" == 1 ]] && open "$APPS/Transcriber.app"
    return 0
}

main "$@"
