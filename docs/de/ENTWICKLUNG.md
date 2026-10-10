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

## Sprachen

Deutsch ist die Quellsprache: Jeder Oberflächentext im Swift-Code ist der deutsche Schlüssel; die englische Übersetzung
steht in `app/Resources/en.lproj/Localizable.strings` (`de.lproj` bleibt leer, Entwicklungsregion ist `en`, damit jede
andere macOS-Sprache Englisch bekommt). Nach Textänderungen zeigt `app/l10n-check.sh` fehlende oder überzählige
Schlüssel (der Compiler zieht sie heraus, kein Xcode nötig). Statuscodes aus dem Kern (`sicher`, `bestätigt`, …)
übersetzt die App erst bei der Anzeige; in den Dateien bleiben sie deutsch. Der Python-Kern nimmt seine Sprache aus
`TRANSCRIBER_UI_LANG` (setzt die App), sonst `ui_language` in `config.json`, sonst die macOS-Sprache (`transcriber/i18n.py`).
App in einer Sprache testen: `open -n ~/Applications/Transcriber.app --args --ui-test -AppleLanguages '(en)'`.

## Prüfungen

`scripts/check.sh` führt die schnellen Prüfungen aus (rund eine Minute, meist `swift build`): Kern-Tests
(`tests/test_core.py`, `unittest` aus der Standardbibliothek, ohne Modelle), Syntax der Skripte, die Umbenennung
`~/Transkription` → `~/Transcriber` im Installer (`tests/installer_migration.sh`), Vollständigkeit der Übersetzung,
den Versionsvergleich des Update-Hinweises und die Datenschutzprüfung des öffentlichen Exports.
`scripts/check.sh --full` transkribiert zusätzlich einen Satz aus der macOS-Sprachausgabe und prüft mit einer
7-s-Aufnahme, dass Mikrofon und Systemton synchron bleiben, wenn der Systemton erst später einsetzt
(`tests/recording_gap.sh`; baut und installiert die App neu und spielt leise einen Ton). Alles läuft in
Wegwerf-Verzeichnissen (`TRANSCRIBER_DATA`); die echte Stimmdatenbank wird nie berührt. `scripts/make-release.sh`
ruft zuerst `--full` auf und bricht bei Fehlern ab. Ändert sich die Transkript-Ausgabe absichtlich:
`UPDATE_GOLDEN=1 scripts/check.sh` und den Diff von `tests/fixtures/*.md` prüfen.

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
