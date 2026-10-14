# Privacy

**In short:** Transcriber processes everything on your Mac. It does not send audio, transcripts, voices, calendar or
screen contents anywhere. There is no telemetry, no analytics, no account.

## What is stored locally

| Data | Location | Note |
|---|---|---|
| Recordings, transcripts | `~/Transcriber/` | your files |
| **Voice database** | `~/.local/share/transcriber/speakers.db` | **biometric data** (voice embeddings) of the people you named; readable only by you (file mode 0600) |
| Event for a recording | `<recording>.event.json` next to the recording | title and attendees (names, email addresses) |
| Logs | `~/.local/share/transcriber/*.log` | technical messages, no dictation content |

## What is not stored

- **Dictation:** Audio stays in memory only and is discarded after recognition.
- **Screen text** (only “dictation with AI”, optional): recognized in memory, passed to the local Apple model and
  discarded.

## Network

Only the **installer** downloads files: release files from transcriber.teconomix.net, uv/Python from astral.sh,
Python packages from PyPI, the Whisper model from Hugging Face and, if needed, ffmpeg from ffmpeg.martin-riedl.de.
During operation, Transcriber does not access the internet (speech recognition runs with `HF_HUB_OFFLINE=1`) – with
one optional exception: if you agree (the panel asks once; Settings › General), the app reads
`https://transcriber.teconomix.net/latest.txt` once a day to show a hint when a new version is out. The request
carries nothing about you or your recordings; the server sees your IP address and does not log it.

**Problem reports** (ladybug in the panel) are not sent by the app: it creates a ZIP file in your Downloads folder
and opens an email to info@teconomix.net, which you send yourself. The file contains logs, version, Mac model,
macOS, permissions, audio devices and app settings – no recordings, transcripts, voice database or glossary. File
names, event titles, names and email addresses are replaced by placeholders unless you switch that off.

## People you record

Recording conversations and storing voices means processing other people's personal data – and, for voice profiles,
even biometric data. Get the consent of everyone involved before you record and name voices. You can remove
individual people and their voice references in the **Voices…** window or with `transcriber speakers forget NAME`.
