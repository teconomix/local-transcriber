# Drittkomponenten und ihre Lizenzen

Local Transcriber selbst steht unter der MIT-Lizenz (siehe `LICENSE`). Er nutzt die folgenden Modelle und Bibliotheken,
die ihre eigenen Lizenzen behalten. Stand: Version 0.3.0.

## Modelle

| Modell | Lizenz | Wie es auf den Rechner kommt |
|---|---|---|
| [openai/whisper-large-v3-turbo](https://huggingface.co/openai/whisper-large-v3-turbo) in der MLX-Fassung [mlx-community/whisper-large-v3-turbo](https://huggingface.co/mlx-community/whisper-large-v3-turbo) | MIT (OpenAI) | Der Installer lädt es von Hugging Face. |
| [pyannote/speaker-diarization-community-1](https://huggingface.co/pyannote/speaker-diarization-community-1) © pyannoteAI | [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) | Unverändert im Release enthalten (mit Namensnennung), damit kein Hugging-Face-Konto nötig ist. |
| Apple Foundation Model, Apple Vision (Texterkennung) | Bestandteil von macOS | Systemfunktionen, nichts wird mitgeliefert. |

## Bibliotheken (Python, per Installer aus PyPI)

| Paket | Lizenz |
|---|---|
| mlx, mlx-whisper | MIT |
| pyannote.audio, pyannote.core, pyannote.pipeline | MIT |
| torch | BSD-3-Clause (u. a.) |
| torchaudio | BSD |
| lightning | Apache-2.0 |
| numpy, scipy, numba, soundfile | BSD |
| tiktoken, mcp, asteroid-filterbanks | MIT |
| huggingface_hub | Apache-2.0 |

## Werkzeuge

| Werkzeug | Lizenz | Hinweis |
|---|---|---|
| [ffmpeg](https://ffmpeg.org) | LGPL/GPL (je nach Build) | **Nicht mitgeliefert.** Vorhandenes ffmpeg (z. B. Homebrew) wird genutzt; sonst lädt der Installer einen statischen Build von [ffmpeg.martin-riedl.de](https://ffmpeg.martin-riedl.de) direkt auf den Rechner des Nutzers. |
| [uv](https://github.com/astral-sh/uv) | MIT / Apache-2.0 | Lädt der Installer von astral.sh. |

Die App (Swift) nutzt ausschließlich Frameworks von macOS (SwiftUI, AVFoundation, Core Audio, ScreenCaptureKit,
EventKit, FoundationModels, Vision) und keine Fremdbibliotheken.
