# Features

## Everything local

Recording, speech recognition, speaker recognition, the voice database and the AI features all run on the Mac. After
installation, Transcriber needs no internet connection. There is no account, no subscription, no telemetry. Details:
[PRIVACY.md](PRIVACY.md).

## Recording

- **One button** in the menu bar: “Start recording”, with the microphone selection next to it.
- **Two tracks:** microphone (you and anyone in the room with you) and system audio (the others in the call). System
  audio is captured via a Core Audio process tap – this only needs the “System Audio Recording” permission, not screen
  recording.
- **Apple voice processing** for the microphone (level, noise and echo suppression), can be turned off.
- Recordings are saved to `~/Transcriber/Recordings/` (`Aufnahmen` on a Mac set to German) and transcribed automatically afterwards.

## Transcription

- **Whisper large-v3-turbo** via MLX on the GPU: ~50× real time (47 min of audio in ~1 min), plus speaker
  recognition at ~28× real time.
- **About 100 languages** (all that Whisper knows). Initially offered are German, English, Spanish and French; select
  or deselect more in Settings › Recording › “Languages to choose from”. Widely spoken languages work best, rare ones
  noticeably worse.
- **Output** next to the audio file: `<name>.md` (readable, with speakers and timestamps), `<name>.transcript.json`
  (complete, machine-readable), optionally `<name>.srt` (subtitles).
- **Glossary** for names and technical terms: fixed replacements after recognition (`transcriber vocab 'dG = DG, D.G.'`).
- **Transcribing files:** “Transcribe file…” in the panel, or simply drop them into `~/Transcriber`
  (folder watcher, optional). Video and audio formats that ffmpeg can read.

## Who said what

- **Speaker diarization** with pyannote community-1.
- **Voice database:** Anyone you name once is recognized by Transcriber in future recordings. Every confirmation
  improves the references.
- **Honest uncertainty:** Names assigned with confidence appear without a marker, probable ones as “Name (?)”, unknown
  ones as “Speaker A/B/…”. The thresholds depend on speaking time (under 15 s never “confident”).
- **Naming in the panel:** ✓ accepts a suggestion, ✎ opens the name field with suggestions from the voice database
  and the calendar attendees.
- **Two tracks:** In calls, Transcriber separates “me” and “the others” by track (100 % in testing), even when the
  speaker echoes back into the microphone.

## Video calls

- **Automatic detection:** If Teams, Zoom, FaceTime, Slack, Webex, Discord or a browser (Meet, Teams in the browser)
  uses the microphone for more than 5 seconds, a notification asks “Record?”. Recording only starts when you click.
- **Automatic stop:** A recording started this way ends 15 seconds after the call and is transcribed.

## Calendar

- If an event is running when a recording starts, its **title and attendees** are saved: the title becomes the file
  name, the attendees are suggested when naming speakers and cap the number of speakers searched for.
- Your own events take precedence over events from shared calendars. You choose which calendars count in Settings.

## Meaningful file names

“2026-10-10 14-03 Budget planning Q4” instead of “Recording 2026-10-10 14-03” – from the calendar event or, if none
was running, generated from the content by Apple Intelligence (macOS 26). The transcript and the voice database are
updated accordingly.

## Dictation everywhere

- **Hold the right ⌘, speak, release:** The text appears at the cursor – in any app, including Terminal.
  10 seconds of dictation are recognized in ~0.2 seconds.
- **Start sound** exactly when the microphone is actually recording; a small indicator at the cursor shows the state
  (starting, recording, recognizing).
- **Right ⌥ = clean up with AI** (macOS 26, Apple Intelligence, local): removes filler words, adds punctuation,
  writes spoken file names correctly (“dictate dot py” → `dictate.py`). Optionally it also reads the text of the
  active window to spell names correctly. If the result deviates too much, the raw text is inserted.
- Keys are freely selectable (right ⌘/⌥/⌃, fn). The clipboard is preserved.

## For power users

- **Command line:** `transcriber transcribe FILE`, `who`, `name`, `confirm`, `speakers`, `vocab`, `rename`, `watch`.
- **MCP server** (`transcriber-mcp`): tools `transcribe`, `who`, `name_speaker`, `confirm_speakers`,
  `list_speakers` for AI agents such as Claude.
- **Folder watcher** as a LaunchAgent: puts results next to every new file in `~/Transcriber`.
- **Settings** in `~/.local/share/transcriber/config.json` (thresholds, formats, number of speakers …).
