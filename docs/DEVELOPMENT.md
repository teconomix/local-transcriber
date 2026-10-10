# Development

## Building

```bash
git clone https://github.com/teconomix/local-transcriber.git && cd local-transcriber

# Python core (editable) into the environment the app also uses
uv venv --python 3.12 ~/.local/share/transcriber/venvs/app
VIRTUAL_ENV=~/.local/share/transcriber/venvs/app uv pip install -e '.[bench]'
ln -sf ~/.local/share/transcriber/venvs/app/bin/transcriber ~/.local/bin/transcriber

# App (Command Line Tools are enough, no Xcode needed) → ~/Applications/Transcriber.app
app/build-app.sh
```

Models: `hf download mlx-community/whisper-large-v3-turbo`; pyannote community-1 either via Hugging Face
(account + accept the conditions) or unpacked into `~/.local/share/transcriber/models/speaker-diarization-community-1`.

**Code signing:** `build-app.sh` signs with a self-created certificate from a dedicated keychain
(`~/.local/share/transcriber/signing/`), if present – then the macOS permissions are kept across rebuilds.
Otherwise it signs ad hoc (permissions are requested again after every build).

## Languages

German is the source language: every UI text in the Swift code is the German key; the English translation lives in
`app/Resources/en.lproj/Localizable.strings` (`de.lproj` stays empty, the development region is `en`, so any other
macOS language gets English). After changing UI texts, `app/l10n-check.sh` lists missing or obsolete keys (it lets the
compiler extract them, no Xcode needed). Status codes from the core (`sicher`, `bestätigt`, …) are translated in the
app at display time and stay German in the files. The Python core picks its language from `TRANSCRIBER_UI_LANG`
(set by the app), then `ui_language` in `config.json`, then the macOS language (`transcriber/i18n.py`).
Test the app in a language: `open -n ~/Applications/Transcriber.app --args --ui-test -AppleLanguages '(en)'`.

## Checks

`scripts/check.sh` runs the fast checks (about a minute, mostly `swift build`): core tests (`tests/test_core.py`,
standard-library `unittest`, no models), script syntax, the installer's `~/Transkription` → `~/Transcriber` rename
(`tests/installer_migration.sh`), translation completeness, the update version comparison and the public export's
privacy check. `scripts/check.sh --full` adds a real transcription of a sentence spoken by macOS text-to-speech and a 7-second
recording that checks microphone and system audio stay in sync when system audio starts late (`tests/recording_gap.sh`;
it rebuilds and installs the app and plays a quiet sound).
Everything runs in throw-away directories (`TRANSCRIBER_DATA`); the real voice database is never touched.
`scripts/make-release.sh` runs `--full` first and stops on failure. If the transcript output changes on purpose:
`UPDATE_GOLDEN=1 scripts/check.sh` and review the diff of `tests/fixtures/*.md`.

## App self-tests

`open -n ~/Applications/Transcriber.app --args <test>` – result in `~/.local/share/transcriber/app.log`:

| Test | Checks |
|---|---|
| `--latency-test` | microphone start time (raw, voice processing, prepared) |
| `--tap-test` | system audio via process tap (silent) |
| `--calendar-test` | calendar access, today's events, ranking |
| `--cleanup-test` | dictation cleanup with screen text |
| `--title-test FILE.transcript.json …` | title suggestions without renaming |
| `--ui-test` | takes screenshots of the panel and settings → `ui-*.png` |

## Measurements

The decisions (model choice, track separation, speaker assignment thresholds) were based on measurement scripts run on
real recordings with listened-to reference transcripts. These scripts and data are tied to private recordings and are
therefore not in the public repo; the results are noted as comments at the relevant places in the code.

## Release

```bash
echo 0.3.1 > VERSION
scripts/make-release.sh          # → dist/download/<version>/, dist/install.sh, dist/latest.txt
website/deploy.sh                # website + dist/ to the web server
```
