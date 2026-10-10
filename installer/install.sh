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
ask()  {  # ask "Frage" → 0 bei ja; ohne Terminal (curl | bash) wird über /dev/tty gefragt
    [[ "$YES" == 1 ]] && return 0
    local a; read -r -p "  $1 [j/N] " a </dev/tty 2>/dev/null || return 1
    [[ "$a" =~ ^[jJyY] ]]
}

main() {
    LAUNCH=1; WATCH=1; YES=0
    for a in "$@"; do case "$a" in
        --no-launch) LAUNCH=0 ;; --no-watch) WATCH=0 ;; --yes) YES=1 ;;
        *) die "unbekannte Option: $a" ;; esac; done

    printf '\n\033[1mTranscriber %s – Installation\033[0m\n\n' "$VERSION"

    # 1. Voraussetzungen ------------------------------------------------------------------------
    say "Voraussetzungen prüfen"
    [[ "$(uname -s)" == Darwin ]] || die "Nur für macOS."
    [[ "$(uname -m)" == arm64 ]] || die "Nur für Macs mit Apple Silicon (M1 oder neuer) – die Spracherkennung nutzt MLX."
    [[ $EUID -ne 0 ]] || die "Bitte nicht mit sudo ausführen – installiert wird ins eigene Benutzerkonto."
    local mac; mac=$(sw_vers -productVersion)
    [[ "${mac%%.*}" -ge 14 ]] || die "macOS 14 Sonoma oder neuer nötig (gefunden: $mac)."
    [[ "${mac%%.*}" -ge 26 ]] || warn "macOS $mac: KI-Funktionen (Diktat aufräumen, Dateinamen) brauchen macOS 26 mit Apple Intelligence."
    local free; free=$(df -g "$HOME" | awk 'NR==2 {print $4}')
    [[ "$free" -ge 8 ]] || die "Zu wenig Speicherplatz: $free GB frei, nötig sind etwa 8 GB."
    ok "macOS $mac, Apple Silicon, $free GB frei"

    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT   # Wert jetzt einsetzen: der Hook läuft nach dem Ende von main
    mkdir -p "$DATA/bin" "$DATA/models" "$APPS" "$HOME/.local/bin" "$HOME/Transkription"

    # 2. Release-Dateien ------------------------------------------------------------------------
    say "Transcriber $VERSION laden"
    local rel="$BASE/download/$VERSION"
    for f in SHA256SUMS "Transcriber-$VERSION.zip" "transcriber-$VERSION.tar.gz" "pyannote-community-1.tar.gz" uninstall.sh; do
        curl -fsSL --retry 3 -o "$tmp/$f" "$rel/$f" || die "Download fehlgeschlagen: $rel/$f"
    done
    (cd "$tmp" && shasum -a 256 -c SHA256SUMS --quiet) || die "Prüfsumme stimmt nicht – Download beschädigt oder manipuliert."
    ok "Prüfsummen stimmen"

    # 3. Python-Umgebung --------------------------------------------------------------------------
    say "Python-Umgebung einrichten (uv, Python 3.12, Pakete – dauert ein paar Minuten)"
    local uv="$DATA/bin/uv"
    if [[ ! -x "$uv" ]]; then
        curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR="$DATA/bin" UV_NO_MODIFY_PATH=1 sh >/dev/null \
            || die "uv konnte nicht installiert werden."
    fi
    "$uv" venv --quiet --allow-existing --python 3.12 "$DATA/venvs/app" || die "Python-Umgebung konnte nicht angelegt werden."
    "$uv" pip install --quiet --python "$DATA/venvs/app/bin/python" "$tmp/transcriber-$VERSION.tar.gz" \
        || die "Python-Pakete konnten nicht installiert werden."
    # uv endet bei Netzfehlern gelegentlich mit Status 0 und unvollständiger Umgebung – deshalb Importe prüfen.
    "$DATA/venvs/app/bin/python" -c "import mlx_whisper, pyannote.audio, transcriber.pipeline" 2>/dev/null \
        || die "Python-Pakete unvollständig – bitte den Installer erneut ausführen."
    ln -sf "$DATA/venvs/app/bin/transcriber" "$HOME/.local/bin/transcriber"
    ok "Python-Umgebung bereit"

    # 4. ffmpeg -----------------------------------------------------------------------------------
    say "ffmpeg"
    if [[ -x "$DATA/bin/ffmpeg" && -x "$DATA/bin/ffprobe" ]] || { command -v ffmpeg && command -v ffprobe; } >/dev/null 2>&1; then
        ok "vorhanden"
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
            [[ -n "$url" ]] || die "ffmpeg: Download-Adresse nicht erreichbar (ffmpeg.martin-riedl.de). Alternativ: brew install ffmpeg"
            curl -fsSL --retry 3 -o "$tmp/$t.zip" "$url" && curl -fsSL -o "$tmp/$t.zip.sha256" "$url.sha256" \
                || die "ffmpeg: Download fehlgeschlagen."
            [[ "$(shasum -a 256 "$tmp/$t.zip" | cut -d' ' -f1)" == "$(cut -d' ' -f1 "$tmp/$t.zip.sha256")" ]] \
                || die "ffmpeg: Prüfsumme stimmt nicht."
            unzip -oq "$tmp/$t.zip" -d "$DATA/bin" && chmod +x "$DATA/bin/$t"
            "$DATA/bin/$t" -version >/dev/null 2>&1 || die "$t lässt sich nicht starten."
        done
        ok "ffmpeg installiert (statischer Build)"
    fi

    # 5. Modelle ----------------------------------------------------------------------------------
    say "Modelle"
    rm -rf "$DATA/models/speaker-diarization-community-1"
    tar -xzf "$tmp/pyannote-community-1.tar.gz" -C "$DATA/models"
    ok "Sprechererkennung (pyannote community-1, CC-BY-4.0)"
    say "Spracherkennungsmodell laden (Whisper large-v3-turbo, ~3 GB – kann dauern)"
    # Über Python statt `hf download`: ohne Werbe-Hinweis der CLI und ohne Token-Warnung des Servers, Balken bleibt
    "$DATA/venvs/app/bin/python" -c "import sys; from huggingface_hub import snapshot_download, logging as l
l.set_verbosity_error(); snapshot_download(sys.argv[1])" "$WHISPER" >/dev/null || die "Whisper-Modell konnte nicht geladen werden (Hugging Face erreichbar?)."
    ok "Whisper large-v3-turbo"

    # 6. App ----------------------------------------------------------------------------------------
    say "App installieren"
    osascript -e 'quit app "Transcriber"' >/dev/null 2>&1 || true
    sleep 1
    rm -rf "$APPS/Transcriber.app"
    ditto -x -k "$tmp/Transcriber-$VERSION.zip" "$APPS"
    xattr -dr com.apple.quarantine "$APPS/Transcriber.app" 2>/dev/null || true
    cp "$tmp/uninstall.sh" "$DATA/uninstall.sh"; chmod +x "$DATA/uninstall.sh"
    ok "$APPS/Transcriber.app"

    # 7. Ordnerwächter (optional) -----------------------------------------------------------------
    local plist="$HOME/Library/LaunchAgents/net.teconomix.transcriber.watch.plist"
    if [[ -f "$plist" ]]; then
        launchctl bootout "gui/$(id -u)" "$plist" 2>/dev/null || true
        launchctl bootstrap "gui/$(id -u)" "$plist" && ok "Ordnerwächter neu gestartet"
    elif [[ "$WATCH" == 1 ]] && ask "Ordner ~/Transkription überwachen (abgelegte Audiodateien automatisch transkribieren)?"; then
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
        launchctl bootstrap "gui/$(id -u)" "$plist" && ok "Ordnerwächter läuft"
    fi

    # 8. Fertig -------------------------------------------------------------------------------------
    printf '\n\033[1;32mFertig.\033[0m Transcriber %s ist installiert.\n\n' "$VERSION"
    cat <<'TXT'
  Beim ersten Aufnehmen fragt macOS nach Mikrofon und Systemaudio – bitte erlauben.
  Diktat (Taste halten, sprechen, loslassen): in den Einstellungen einschalten; dafür braucht es
  die Freigabe „Bedienungshilfen“. Kalender-Termine als Dateinamen: Freigabe „Kalender“.

  Kommandozeile: ~/.local/bin/transcriber  (ggf. ~/.local/bin zum PATH hinzufügen)
  Deinstallieren: bash ~/.local/share/transcriber/uninstall.sh
TXT
    [[ "$LAUNCH" == 1 ]] && open "$APPS/Transcriber.app"
    return 0
}

main "$@"
