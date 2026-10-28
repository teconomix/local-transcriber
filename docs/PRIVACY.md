# Privacy

**In short:** Transcriber processes everything on your Mac. It does not send audio, transcripts, voices, calendar or
screen contents anywhere – the only exception is the AI evaluation with a cloud provider, if you set it up yourself
(see Network). There is no telemetry, no analytics, no account.

## What is stored locally

| Data | Location | Note |
|---|---|---|
| Recordings, transcripts | `~/Transcriber/` | your files |
| **Voice database** | `~/.local/share/transcriber/speakers.db` | **biometric data** (voice embeddings) of the people you named; readable only by you (file mode 0600) |
| Event for a recording | `<recording>.event.json` next to the recording | title and attendees (names, email addresses) |
| Summary | `<recording>.summary.md` next to the transcript | only if you start an AI evaluation |
| AI settings, your templates | `config.json` (section `ai`), `prompts/` in `~/.local/share/transcriber/` | keys for cloud providers are **not** stored there but in the keychain |
| Working copies | `~/.local/share/transcriber/cache/` | audio as WAV and the speech recognition, for re-analysis; deleted together with the recording (User Guide › Deleting) |
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
carries nothing about you or your recordings; the server sees your IP address and keeps it only shortened (e.g. 82.98.0.0) in its access log, which is deleted
after 7 days; only daily totals are kept (see the website's privacy policy).

**AI evaluation** (optional, Settings › AI): with a **local** model (Ollama, LM Studio, MTPLX, your own server on
`localhost`) everything stays on the Mac. With a **cloud provider**, Transcriber sends the transcript together with
title, date and participant names directly to that provider using your key – by default only on click; names of
speakers and calendar attendees are replaced with placeholders first and put back in the answer (can be switched off;
other personal details in the content of the conversation remain). The provider's terms apply.

**Continue in Claude / Codex** opens that program with a prepared text; nothing is sent until you do so there.

**Problem reports** (ladybug in the panel) are not sent by the app: it creates a ZIP file in its data folder
(`~/.local/share/transcriber/reports/`, deleted after 14 days)
and opens an email to info@teconomix.net, which you send yourself. The file contains logs, version, Mac model,
macOS, permissions, audio devices and app settings – no recordings, transcripts, voice database or glossary. File
names, event titles, names and email addresses are replaced by placeholders unless you switch that off.

## People you record

Recording conversations and storing voices means processing other people's personal data – and, for voice profiles,
even biometric data. Get the consent of everyone involved before you record and name voices. You can remove
individual people and their voice references in the **Voices…** window or with `transcriber speakers forget NAME`.
Deleting a recording with “Delete everything” also deletes the voices stored from that conversation.
