# Third-party components and their licenses

Local Transcriber itself is licensed under the MIT License (see `LICENSE`). It uses the following models and
libraries, which keep their own licenses. As of version 0.3.0.

## Models

| Model | License | How it gets onto the computer |
|---|---|---|
| [openai/whisper-large-v3-turbo](https://huggingface.co/openai/whisper-large-v3-turbo) in the MLX version [mlx-community/whisper-large-v3-turbo](https://huggingface.co/mlx-community/whisper-large-v3-turbo) | MIT (OpenAI) | The installer downloads it from Hugging Face. |
| [pyannote/speaker-diarization-community-1](https://huggingface.co/pyannote/speaker-diarization-community-1) © pyannoteAI | [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) | Included unmodified in the release (with attribution), so that no Hugging Face account is needed. |
| Apple Foundation Model, Apple Vision (text recognition) | Part of macOS | System features, nothing is bundled. |

## Libraries (Python, installed from PyPI by the installer)

| Package | License |
|---|---|
| mlx, mlx-whisper | MIT |
| pyannote.audio, pyannote.core, pyannote.pipeline | MIT |
| torch | BSD-3-Clause (among others) |
| torchaudio | BSD |
| lightning | Apache-2.0 |
| numpy, scipy, numba, soundfile | BSD |
| tiktoken, mcp, asteroid-filterbanks | MIT |
| huggingface_hub | Apache-2.0 |

## Tools

| Tool | License | Note |
|---|---|---|
| [ffmpeg](https://ffmpeg.org) | LGPL/GPL (depending on the build) | **Not bundled.** An existing ffmpeg (e.g. Homebrew) is used; otherwise the installer downloads a static build from [ffmpeg.martin-riedl.de](https://ffmpeg.martin-riedl.de) directly onto the user's computer. |
| [uv](https://github.com/astral-sh/uv) | MIT / Apache-2.0 | Downloaded by the installer from astral.sh. |

The app (Swift) uses only macOS frameworks (SwiftUI, AVFoundation, Core Audio, ScreenCaptureKit, EventKit,
FoundationModels, Vision) and no third-party libraries.
