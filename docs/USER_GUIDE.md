# User Guide

## Language

Transcriber follows the macOS language and is available in German and English (any other macOS language gets English). To use a different language for
Transcriber only, go to **System Settings › General › Language & Region › Applications**.

## The panel

Clicking the waveform icon in the menu bar opens the panel:

1. **Start recording** – next to it, the microphone. While recording: elapsed time, level, “Stop recording”.
2. **Transcribe file…** – next to it, the language (applies to recordings, files and dictation; which languages are offered is set in Settings).
3. **Dictation line** – shows which keys are assigned; orange/red if a permission is missing. The switch on the right
   turns dictation on or off (off frees the keys and the memory of the dictation service).
4. **Transcriptions** – the most recent jobs with progress, “Open”, “Show in Finder” and the recognized speakers.
5. At the bottom: Open folder · Voices… · Settings… (⌘,) · Quit.

## Recording a meeting

1. Choose the microphone (usually “System default”), **Start recording**.
2. The first time, macOS asks for **Microphone** and **System Audio Recording** access – allow both.
3. **Stop recording.** Transcriber transcribes and names the file; a notification reports “Transcript ready”.
4. **Open** shows the transcript (Markdown).

## Recording a video call

Just start the call. After a few seconds, “Call in Teams detected – Record?” appears → **Record**.
When you hang up, the recording stops on its own. Alternatively, use the button as above.

Tip: With headphones, the separation between you and the others is cleanest; it also works over speakers.

## Naming speakers

The recognized speakers are listed under each finished transcript:

- **Name** – recognized with confidence.
- **Name (?)** – probable; **✓ accept** confirms.
- **Speaker A** – unknown; **✎** opens the name field. Below it are suggestions (known voices 👤, calendar
  attendees 📅). Clicking a suggestion assigns the name immediately.
- **Accept all matches** confirms everything at once.

Every name you assign improves recognition in future recordings. The **Voices…** window shows the voice database and
lets you remove individual references or people. Ideally, give people their **first and last name**.

## Dictation

1. Turn it on with the switch in the panel or in **Settings › Dictation**. macOS asks for **Accessibility** access – allow it (needed to detect the key
   and insert the text).
2. Click into any text field, **hold the right ⌘**, wait for the sound, speak, release.
3. With the **right ⌥** instead of ⌘, Apple Intelligence cleans up the text (macOS 26).

Note: On a German keyboard, the right ⌥ also types `@` and `€`. This is recognized as a keyboard shortcut and
ignored; if the short start sound bothers you, choose the right ⌃ in Settings.

## Transcribing files

- **Transcribe file…** in the panel, or
- put the file into `~/Transcriber` if the folder watcher is active – the result appears next to it.

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
- **Dictation does not respond:** check the Accessibility permission; after an update, remove the entry if necessary and
  allow it again.
- **No audio from the others in the call:** check the “System Audio Recording” permission.
- **Transcription failed:** error message in the panel; `transcriber transcribe FILE` in Terminal shows details.
