# Features

## Everything local

Recording, speech recognition, speaker recognition, the voice database and the AI features all run on the Mac. After
installation, Transcriber needs no internet connection – unless you explicitly choose a cloud model for the AI evaluation. There is no account, no subscription, no telemetry. Details:
[PRIVACY.md](PRIVACY.md).

## Recording

- **One button** in the menu bar: “Start recording”, with the microphone selection next to it.
- **Two tracks:** microphone (you and anyone in the room with you) and system audio (the others in the call). System
  audio is captured via a Core Audio process tap – this only needs the “System Audio Recording” permission, not screen
  recording.
- **Apple voice processing** for the microphone (level, noise and echo suppression), can be turned off; off during calls,
  so the call app keeps hearing you.
- Recordings are saved to `~/Transcriber/Recordings/` (`Aufnahmen` on a Mac set to German) and transcribed automatically afterwards.

## Transcription

- **Whisper large-v3-turbo** via MLX on the GPU: ~50× real time (47 min of audio in ~1 min), plus speaker
  recognition at ~28× real time.
- **Two speech recognition models:** Whisper turbo in 8-bit (default for new installations, 0.9 GB) or 16-bit
  (1.6 GB) – measured just as accurate; 8-bit needs about 0.8 GB less memory (dictation too). Switch in Settings ›
  Recording › Speech recognition (downloads the model if needed) and delete the unused one there. Installations
  from before 0.10 keep 16-bit. Command line: `transcriber model [turbo|turbo-8bit] [--download] [--remove NAME]`.
- **About 100 languages** (all that Whisper knows). Initially offered are German, English, Spanish and French; select
  or deselect more in Settings › Recording › “Languages to choose from”. Widely spoken languages work best, rare ones
  noticeably worse. If a recording is clearly in another language than selected, the detected one is used.
- **Output** next to the audio file: `<name>.txt` (readable, with speakers and timestamps; Markdown
  `.md` selectable in Settings › Recording), `<name>.transcript.json`
  (complete, machine-readable), optionally `<name>.srt` (subtitles).
- **Deleting:** recording only (transcript stays) or everything incl. the voices from that conversation; optionally
  all transcribed audio and video files in `~/Transcriber` are deleted automatically 30 days after transcription. Working copies are always deleted along.
- **Glossary** for names and technical terms: fixed replacements after recognition, in the app under Settings › Glossary
  (or `transcriber vocab 'dG = DG, D.G.'`); can be applied to existing transcripts afterwards.
- **Repair:** passages where Whisper drops all punctuation are re-recognized individually and only taken over if the
  content stays the same; word loops (“Happy Happy Happy …”) are cut.
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
- **Also during a recording** (notes in a call): dictation uses the recording's microphone audio.

## Evaluating with AI

- After transcription, a language model turns the conversation into **minutes** (key points, decisions, action items,
  open questions), a **short summary**, an **order in the five-paragraph format** (operation order, with “Still to
  clarify”), a **supervision and coaching note** (without interpretation), **key statements with quotes** or a
  **follow-up email**. Templates can be edited, your own added.
- **Locally** via Ollama, LM Studio, MTPLX or any server with an OpenAI-style API – the conversation never leaves the
  Mac. **Cloud** via OpenAI, Anthropic, Mistral, OpenRouter with your own key: only on click (automation only when
  explicitly enabled), names replaced with placeholders first (can be switched off).
- **Local server on demand:** with a start command (e.g. `ollama serve`), Transcriber starts the server when needed
  and stops it again after a set idle time or when the app quits.
- On click or automatically after every transcription; result as `<name>.summary.md` next to the transcript, the
  panel shows the first key points and action items. New speaker names carry over into the summary.
- **Continue** in Claude, Claude Code or Codex with one click (the app opens with a prepared text, nothing is sent). In
  the **Obsidian plugin**, the summary appears as its own section with action items to check off.

## For power users

- **Command line:** `transcriber transcribe FILE`, `who`, `name`, `confirm`, `speakers`, `vocab`, `rename`, `summarize`, `watch`.
- **MCP server** (`transcriber-mcp`): tools `transcribe`, `who`, `name_speaker`, `confirm_speakers`,
  `list_speakers`, `show_glossary`, `add_to_glossary`, `apply_glossary`, `recent_transcripts`, `read_transcript`,
  `get_summary`, `list_templates`, `summarize_transcript` for AI agents such as Claude; plus every template as a prompt
  (in Claude Desktop e.g. `/protokoll`) that the agent applies with its own model – e.g. “it says
  Kali instead of KI, remember that” adds the spelling to the glossary and fixes the current transcript.
- **Folder watcher** as a LaunchAgent: puts results next to every new file in `~/Transcriber` and its subfolders –
  except the app's own recordings folder, where the app starts transcription itself. A file renamed or moved in
  Finder keeps its transcript (recognized by content) instead of being transcribed again.
- **Settings** in `~/.local/share/transcriber/config.json` (thresholds, formats, number of speakers …).
