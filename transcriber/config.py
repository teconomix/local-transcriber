"""Pfade und Voreinstellungen. Alles Dauerhafte liegt unter DATA (außerhalb von Syncthing)."""
import json
import os
from pathlib import Path

DATA = Path(os.environ.get("TRANSCRIBER_DATA", "~/.local/share/transcriber")).expanduser()
DB = DATA / "speakers.db"          # Stimmen = biometrische Daten, nie synchronisieren
CACHE = DATA / "cache"             # vorbereitete WAVs je Auftrag
CONFIG = DATA / "config.json"
JOBS = DATA / "jobs"               # Statusdateien laufender/fertiger Aufträge (für die App)

DEFAULTS = {
    "language": "de",              # Whisper-Sprachcode: de, en, es, fr, …
    "watch_dir": "~/Transkription",
    "formats": ["md", "json"],     # zusätzlich möglich: "srt"
    "min_speakers": 2,
    "max_speakers": 6,
    "vocab_file": str(DATA / "vocab.txt"),  # Glossar, Format siehe glossary.py
    "glossary_prompt": False,      # Glossar zusätzlich als Whisper-Prompt (gemessen: schadet, siehe asr.py)
    # Stimmenabgleich (Kosinus). Gemessen 2026-10-08: gleiche Person 0,75–0,93, verschiedene ≤ 0,42.
    "match_sure": 0.65,
    "match_maybe": 0.50,
    "min_speech_s": 60,            # darunter gilt die strengere Schwelle match_sure_short
    "match_sure_short": 0.75,      # 15–60 s Sprechzeit: sicher erst ab dieser Ähnlichkeit (speakers.sure_match)
    "min_sure_s": 15,              # darunter nie „sicher“
    "min_enroll_s": 15,            # kürzere Cluster nicht als Stimmreferenz speichern
    # Zwei Tonspuren (App: Mikrofon + Systemton): auto = getrennt auswerten, außer die Spuren sind Kopien desselben
    # Raumklangs (Handy mit zwei Mikrofonen: ≥ copy_share der Fenster korreliert) → gemischt. Siehe bench/SPUREN.md.
    "track_mode": "auto",          # auto | getrennt | gemischt
    "copy_share": 0.9,
    "merge_sim": 0.6,              # Cluster einer Spur ab dieser Stimmähnlichkeit zusammenlegen
}


def load():
    cfg = dict(DEFAULTS)
    if CONFIG.exists():
        cfg.update(json.loads(CONFIG.read_text()))
    return cfg


def offline_env():
    """Keine Netzwerkzugriffe zur Laufzeit: Modelle müssen im HF-Cache liegen. Außerdem DATA/bin (vom Installer
    gelegtes ffmpeg) vorn in den PATH – mlx-whisper ruft beim Laden von Audiodateien selbst `ffmpeg` auf."""
    os.environ.setdefault("HF_HUB_OFFLINE", "1")
    os.environ.setdefault("TRANSFORMERS_OFFLINE", "1")
    b = str(DATA / "bin")
    if b not in os.environ.get("PATH", "").split(":"):
        os.environ["PATH"] = b + ":" + os.environ.get("PATH", "")
