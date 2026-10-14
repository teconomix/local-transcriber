# User Guide

## Language

Transcriber follows the macOS language and is available in German and English (any other macOS language gets English). To use a different language for
Transcriber only, go to **System Settings › General › Language & Region › Applications**.

## The panel

Clicking the waveform icon in the menu bar opens the panel:

1. **Start recording** – next to it, the microphone. While recording: elapsed time, level, “Stop recording”. During a
   detected call the button reads **Record call** and uses the microphone the call app uses (see below).
2. **Transcribe file…** – next to it, the language (applies to recordings, files and dictation; which languages are
   offered is set in Settings) and the **number of people** (Auto, or exactly 1–6 – for the next recording or file only).
3. **Dictation line** – shows which keys are assigned; orange/red if a permission is missing. The switch on the right
   turns dictation on or off (off frees the keys and the memory of the dictation service).
4. **Transcriptions** – the most recent jobs with progress, the recognized speakers and *Open · Show in Finder ·
   Rename · Re-analyze…*. *Re-analyze…* offers **Match names again** (only re-matches against the voice database, in
   a second) and **Separate speakers again** with Automatic or 1–10 people (when two people were merged or one was split).
5. At the bottom: **Folder** · **Settings** (⌘,) · ladybug (report a problem) · **Quit**.

## Recording a meeting

1. Choose the microphone (usually “System default”), **Start recording**.
2. The first time, macOS asks for **Microphone** and **System Audio Recording** access – allow both.
3. **Stop recording.** Transcriber transcribes and names the file; a notification reports “Transcript ready”.
4. **Open** shows the transcript (Markdown).

## Recording a video call

Just start the call. After a few seconds, “Call in Teams detected – Record?” appears → **Record**.
When you hang up, the recording stops on its own. Alternatively, use **Record call** in the panel.

Call recordings use the **microphone the call app uses** and follow it if you switch microphones during the call
(the panel shows “Microphone as in the call: …”; a switch costs up to a second of audio). The audio of the others is
recorded regardless of whether it plays through speakers or headphones. Microphones other than the system default
are recorded without Apple's voice processing.

If the notification disappears too quickly: *System Settings › Notifications › Transcriber › Alert style: Alerts*
keeps it until you click.

Tip: With headphones, the separation between you and the others is cleanest; it also works over speakers.

## Naming speakers

The recognized speakers are listed under each finished transcript:

- **Name** – recognized with confidence.
- **Name (?)** – probable; **✓ accept** confirms.
- **Speaker A** – unknown; **✎** opens the name field. Below it are suggestions (known voices 👤, calendar
  attendees 📅). Clicking a suggestion assigns the name immediately.
- **Accept all matches** confirms everything at once.

Every name you assign improves recognition in future recordings. *Settings › Voices* shows the voice database and
lets you remove individual references or people. Ideally, give people their **first and last name**.

**Sharing voices:** *Settings › Voices › Export…* writes one voice print per selected person (256 numbers and the name – no
recordings, titles or paths) to a `.voices.json` file; *Import…* on another Mac lets you pick who to take over.
Voice prints are biometric data: share them only with the consent of the people concerned. The file is not
encrypted. Name your own voice before importing – otherwise it may be matched to a similar-sounding colleague.

## Dictation

1. Turn it on with the switch in the panel or in **Settings › Dictation**. macOS asks for **Accessibility** access – allow it (needed to detect the key
   and insert the text).
2. Click into any text field, **hold the right ⌘**, wait for the sound, speak, release.
3. With the **right ⌥** instead of ⌘, Apple Intelligence cleans up the text (macOS 26).

Note: On a German keyboard, the right ⌥ also types `@` and `€`. This is recognized as a keyboard shortcut and
ignored; if the short start sound bothers you, choose the right ⌃ in Settings.

## Transcribing files

- **Transcribe file…** in the panel, or
- put the file into `~/Transcriber` if the folder watcher is active – the result appears next to it. The `Recordings`
  folder is the app's: recordings there are transcribed by the app; if one has no transcript (e.g. “Transcribe” was off),
  the panel offers to transcribe it.
- **Rename** a recording in the panel; renamed or moved in Finder, the watcher moves its transcript along.

## Settings

| Tab | Contents |
|---|---|
| General | version, data folder, check for updates once a day (optional) |
| Recording | Record system audio, voice processing, transcribe/name after recording, detect calls, languages to choose from |
| Dictation | on/off, keys (verbatim / with AI), screen text as context, audio, icon at the cursor, voice processing |
| Calendar | use calendar events, choice of calendars |

## Glossary

Enter names and technical terms that are often misrecognized as fixed replacements:

```bash
transcriber vocab 'Claude Code = Cloud-Code, Cloud Code'
```

On the left the desired term, on the right the spellings to be replaced.

## Permissions at a glance

| Permission | Used for | Required? |
|---|---|---|
| Microphone | recording, dictation | yes |
| System Audio Recording (“System Audio Recording Only”) | audio of the others in a call | for calls |
| Notifications | “Transcript ready”, “Call in … detected” | recommended |
| Accessibility | dictation: detect the key, insert the text | only for dictation |
| Calendars (Full Access) | event title and attendees | optional |
| Screen & System Audio Recording | dictation with AI: text of the active window as context | optional |

All permissions can be revoked at any time in **System Settings › Privacy & Security**.

## Troubleshooting

- **Logs:** `~/.local/share/transcriber/app.log` (app), `dictate.log` (dictation), `watch.log` (folder watcher).
- **Report a problem:** ladybug at the bottom of the panel (or *Report a problem…* on a failed transcription) – describe
  what happened; logs and system info are attached to a prepared email (no recordings or transcripts).
- **Dictation does not respond:** check the Accessibility permission; after an update, remove the entry if necessary and
  allow it again.
- **No audio from the others in the call:** check the “System Audio Recording” permission.
- **Transcription failed:** error message in the panel; `transcriber transcribe FILE` in Terminal shows details.
