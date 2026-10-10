"""Sprache der Ausgaben für Menschen (Transkript, Fortschritt, Fehler, CLI): de oder en.

Reihenfolge: Umgebungsvariable TRANSCRIBER_UI_LANG (setzt die App für jeden Kernprozess) → config „ui_language“ →
erste macOS-Sprache (`defaults read -g AppleLanguages`, beginnt mit „de“ → de) → en.
Interne Werte (Status „sicher“/„vermutlich“/…, JSON-Schlüssel) bleiben deutsch und werden nie übersetzt."""
import functools
import os
import subprocess

from . import config

LANGS = ("de", "en")


@functools.lru_cache(maxsize=1)
def _system():
    try:
        out = subprocess.run(["defaults", "read", "-g", "AppleLanguages"], capture_output=True, text=True,
                             timeout=5).stdout
        first = next(l.strip(' \t",') for l in out.splitlines() if l.strip(' \t",()'))
        return "de" if first.lower().startswith("de") else "en"
    except Exception:
        return "en"


@functools.lru_cache(maxsize=1)
def lang():
    v = (os.environ.get("TRANSCRIBER_UI_LANG") or "").strip().lower()[:2]
    if v in LANGS:
        return v
    try:
        v = (config.load().get("ui_language") or "").strip().lower()[:2]
    except Exception:
        v = ""
    return v if v in LANGS else _system()


def t(de, en):
    """Deutscher oder englischer Text je nach lang()."""
    return de if lang() == "de" else en


STATUS = {"sicher": "confident", "bestätigt": "confirmed", "vermutlich": "probably", "unbekannt": "unknown"}


def status(s):
    """Status-Code (bleibt deutsch gespeichert) → Anzeigetext."""
    return s if lang() == "de" else STATUS.get(s, s)
