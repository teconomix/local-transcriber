# Entwicklung

## Bauen

```bash
git clone https://github.com/teconomix/local-transcriber.git && cd local-transcriber

# Python-Kern (editierbar) in die Umgebung, die auch die App nutzt
uv venv --python 3.12 ~/.local/share/transcriber/venvs/app
VIRTUAL_ENV=~/.local/share/transcriber/venvs/app uv pip install -e '.[bench]'
ln -sf ~/.local/share/transcriber/venvs/app/bin/transcriber ~/.local/bin/transcriber

# App (Command Line Tools reichen, kein Xcode nötig) → ~/Applications/Transcriber.app
app/build-app.sh
```

Modelle: `hf download mlx-community/whisper-large-v3-turbo`; pyannote community-1 entweder über Hugging Face
(Konto + Bedingungen akzeptieren) oder entpackt nach `~/.local/share/transcriber/models/speaker-diarization-community-1`.

**Signatur:** `build-app.sh` signiert mit einem selbst erstellten Zertifikat aus einem eigenen Schlüsselbund
(`~/.local/share/transcriber/signing/`), falls vorhanden – dann bleiben die macOS-Freigaben über Neubauten erhalten.
Sonst ad hoc (Freigaben werden nach jedem Bau neu abgefragt).

## Selbsttests der App

`open -n ~/Applications/Transcriber.app --args <test>` – Ergebnis in `~/.local/share/transcriber/app.log`:

| Test | prüft |
|---|---|
| `--latency-test` | Startzeit des Mikrofons (roh, Sprachverarbeitung, vorbereitet) |
| `--tap-test` | Systemton per Process-Tap (stumm) |
| `--calendar-test` | Kalenderzugriff, heutige Termine, Rangfolge |
| `--cleanup-test` | Diktat-Aufräumen mit Bildschirmtext |
| `--title-test DATEI.transcript.json …` | Titelvorschläge ohne Umbenennen |
| `--ui-test` | fotografiert Panel und Einstellungen → `ui-*.png` |

## Messungen

Die Entscheidungen (Modellwahl, Spurtrennung, Schwellen der Sprecherzuordnung) wurden mit Messskripten an echten
Aufnahmen mit gehörten Referenztexten begründet. Diese Skripte und Daten sind an private Aufnahmen gebunden und deshalb
nicht im öffentlichen Repo; die Ergebnisse stehen als Kommentare an den jeweiligen Stellen im Code.

## Release

```bash
echo 0.3.1 > VERSION
scripts/make-release.sh          # → dist/download/<Version>/, dist/install.sh, dist/latest.txt
website/deploy.sh                # Website + dist/ auf den Webserver
```
