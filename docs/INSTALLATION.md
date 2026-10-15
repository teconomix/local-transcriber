# Installation

## Requirements

- Mac with **Apple Silicon** (M1 or newer) – Intel Macs are not supported (MLX).
- **macOS 14 Sonoma** or newer. AI features (dictation cleanup, AI-generated file names) require
  **macOS 26 with Apple Intelligence turned on**.
- About **8 GB** of free disk space (speech recognition model ~3 GB, Python environment ~2 GB).
- 16 GB of memory recommended.
- Internet only during installation. No administrator rights needed.

## Install

Open Terminal (Applications › Utilities › Terminal) and paste:

```bash
curl -fsSL https://transcriber.teconomix.net/install.sh | bash
```

The installer (takes 5–15 minutes depending on your connection):

1. checks the Mac, the macOS version and the free disk space,
2. downloads the release files and verifies their checksums,
3. sets up its own Python environment (uv, Python 3.12, packages from PyPI),
4. uses an existing ffmpeg or downloads a static build,
5. installs the speaker recognition model (included) and downloads the Whisper model from Hugging Face,
6. puts the app in `~/Applications/Transcriber.app` and the command line tool in `~/.local/bin/transcriber`,
7. offers the folder watcher for `~/Transcriber`,
8. starts Transcriber.

Run it again to update. The voice database, settings and transcripts are kept. When updating from 0.5 or older, the
installer renames the data folder `~/Transkription` to `~/Transcriber` (once, nothing is copied).

Options (append after `bash -s --`, e.g. `curl -fsSL …/install.sh | bash -s -- --no-watch`):
`--no-launch` (do not start the app), `--no-watch` (do not offer the folder watcher), `--yes` (no prompts).

### With Homebrew

```bash
brew install --cask teconomix/tap/local-transcriber
```

The cask runs the same installer (`--yes --no-watch`); `brew upgrade` updates, `brew uninstall local-transcriber`
runs the uninstaller (without a terminal prompt it keeps the voice database and the Whisper model). The folder watcher
is not offered here – run the curl installer once and answer “y” if you want it; upgrades keep it running.

Questions or stuck? [GitHub Discussions](https://github.com/teconomix/local-transcriber/discussions).

## First steps

The first time you record, macOS asks for **Microphone** and **System Audio Recording** access. For dictation, turn
dictation on in Settings and allow **Accessibility**. Overview of all permissions: [USER_GUIDE.md](USER_GUIDE.md#permissions-at-a-glance).

## Where things are

| Path | Contents |
|---|---|
| `~/Applications/Transcriber.app` | App |
| `~/.local/share/transcriber/` | Python environment, ffmpeg, speaker recognition model, **voice database** (`speakers.db`), logs |
| `~/.cache/huggingface/hub/` | Whisper model |
| `~/Transcriber/` | Recordings and transcripts (your data) |
| `~/Library/LaunchAgents/net.teconomix.transcriber.watch.plist` | Folder watcher (optional) |

## Uninstall

```bash
bash ~/.local/share/transcriber/uninstall.sh
```

Removes the app, program data and the folder watcher. Asks whether the voice database and the Whisper model should be
deleted. **Recordings and transcripts in `~/Transcriber` are always kept.**

## About code signing

The app is not (yet) notarized by Apple. Because the installer downloads it with `curl`, macOS does not check it via
Gatekeeper, and it starts without a warning. If you download the app file in a browser instead, you have to confirm it
on first launch with right-click › Open.
