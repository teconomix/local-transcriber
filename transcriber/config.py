"""Pfade und Voreinstellungen. Alles Dauerhafte liegt unter DATA (außerhalb von Syncthing)."""
import json
import os
from pathlib import Path

DATA = Path(os.environ.get("TRANSCRIBER_DATA", "~/.local/share/transcriber")).expanduser()
DB = DATA / "speakers.db"          # Stimmen = biometrische Daten, nie synchronisieren
CACHE = DATA / "cache"             # vorbereitete WAVs je Auftrag
CONFIG = DATA / "config.json"
JOBS = DATA / "jobs"               # Statusdateien laufender/fertiger Aufträge (für die App)
# Audio/Video, das transkribiert wird (Wächter, Löschen, Fehlerbericht); .qta = mehrspurige Sprachmemos (ffmpeg liest sie)
MEDIA_EXT = {".m4a", ".mp3", ".wav", ".aac", ".flac", ".ogg", ".opus", ".mp4", ".mov", ".m4v", ".mkv", ".webm", ".caf",
             ".aiff", ".aif", ".qta"}

def secure_data():
    """DATA nur für diesen Benutzer (0700): darin liegen Gesprächsaudio und Volltexte (cache/), sonst mit 0755 für
    andere Konten auf dem Mac lesbar, wenn mkdir(parents=True) auch ~/.local/share neu anlegt."""
    DATA.mkdir(parents=True, exist_ok=True)
    DATA.chmod(0o700)


DEFAULTS = {
    "language": "de",              # Whisper-Sprachcode: de, en, es, fr, …
    "ui_language": None,           # Ausgabesprache de|en; None = macOS-Sprache (i18n.py), App setzt TRANSCRIBER_UI_LANG
    "watch_dir": "~/Transcriber",
    "watch_exclude": ["Aufnahmen", "Recordings"],   # Aufnahmeordner der App: dort startet die App selbst (watch.py)
    "formats": ["md", "json"],     # zusätzlich möglich: "srt"; „md“ = lesbares Transkript, Endung nach text_format
    "text_format": "txt",          # txt = reiner Text (Standard seit 0.8) | md = Markdown; App: Einstellungen › Aufnahme
                                   # (.md öffnet je nach Mac in irgendeinem Programm; Markdown fürs Obsidian-Plugin)
    "min_speakers": 2,
    "max_speakers": 15,            # großzügig: zu viele Cluster führt die Stimmdatenbank wieder zusammen, zu wenige
                                   # mischen Personen unumkehrbar (2026-10-12: 9 Personen, Grenze 6 → zwei in einem Cluster)
    "vocab_file": str(DATA / "vocab.txt"),  # Glossar, Format siehe glossary.py
    "glossary_prompt": False,      # Glossar zusätzlich als Whisper-Prompt (gemessen: schadet, siehe asr.py)
    # "asr_model": turbo (FP16, 1,6 GB) | turbo-8bit (0,86 GB, gleich genau) – ohne Eintrag entscheidet asr.choice
    "repair_flat": True,           # Stellen ohne Satzzeichen einzeln neu erkennen, nur bei Prüfung übernehmen (asr.repair)
    # Stimmenabgleich (Kosinus). Gemessen 2026-10-08: gleiche Person 0,75–0,93, verschiedene ≤ 0,42.
    "match_sure": 0.75,            # ab 60 s; war 0,65 – falsche Personen kamen bis 0,65, richtige ab 0,80 (bench/SCHWELLEN.md)
    "match_maybe": 0.60,           # war 0,50 – Unbekannte bekamen bei 0,51 und 0,596 falsche Namen „(?)“ (bench/SCHWELLEN.md, 2026-10-24)
    "min_speech_s": 60,            # darunter gilt die strengere Schwelle match_sure_short
    "match_sure_short": 0.75,      # 15–60 s Sprechzeit: sicher erst ab dieser Ähnlichkeit (speakers.sure_match)
    "min_sure_s": 15,              # darunter nie „sicher“
    "min_enroll_s": 15,            # kürzere Cluster nicht als Stimmreferenz speichern
    "carry_sim": 0.9,              # Neuauswertung: Bestätigung übernehmen ab dieser Ähnlichkeit zur alten Referenz
    # Zwei Tonspuren (App: Mikrofon + Systemton): auto = getrennt auswerten, außer die Spuren sind Kopien desselben
    # Raumklangs (Handy mit zwei Mikrofonen: ≥ copy_share der Fenster korreliert) → gemischt. Siehe bench/SPUREN.md.
    "language_check": True,        # eindeutig andere Sprache als eingestellt (asr.detect_language) → die erkannte nehmen
    "track_mode": "auto",          # auto | getrennt | gemischt
    "copy_share": 0.9,
    "merge_sim": 0.6,              # Cluster einer Spur ab dieser Stimmähnlichkeit zusammenlegen
    "merge_sim_call": 0.7,         # dasselbe auf der Call-Spur (Codec: verschiedene Stimmen bis 0,63 ähnlich)
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
