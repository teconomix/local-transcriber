"""Alle Transkripte unter dem Datenordner – für das Fenster „Alle Transkriptionen“ der App.

Aufnahmedatum: Dateidatum taugt nicht (synchronisierte Handy-Aufnahmen tragen das Datum der Synchronisierung), daher
creation_time aus den Metadaten der Aufnahme, sonst Kalendertermin, sonst Zeitstempel im Dateinamen, sonst Datum des
Transkripts. Die Metadaten liest ffprobe einmal je Datei; das Ergebnis liegt in DATA/library.json.
"""
import contextlib
import json
import re
import subprocess
from datetime import datetime
from pathlib import Path

from . import audio, config, render, summarize

CACHE = config.DATA / "library.json"
OPEN = {"sicher", "vermutlich", "unbekannt"}        # noch nicht bestätigt


def _local(ts):
    return datetime.fromtimestamp(ts).strftime("%Y-%m-%d %H:%M")


def _from_metadata(src):
    try:
        out = subprocess.run([audio.tool("ffprobe"), "-v", "error", "-show_entries", "format_tags=creation_time",
                              "-of", "json", str(src)], capture_output=True, text=True, timeout=15).stdout
        ct = json.loads(out or "{}").get("format", {}).get("tags", {}).get("creation_time")
    except (OSError, ValueError, subprocess.TimeoutExpired):
        return None
    if not ct or ct.startswith("1970") or ct.startswith("1904"):
        return None
    try:
        return datetime.fromisoformat(ct.replace("Z", "+00:00")).astimezone().strftime("%Y-%m-%d %H:%M")
    except ValueError:
        return None


def recorded(doc, src, cache):
    """Aufnahmedatum „JJJJ-MM-TT HH:MM“ (Ortszeit) und woher es stammt."""
    if src.exists():
        st = src.stat()
        key = f"{src}|{st.st_size}|{int(st.st_mtime)}"
        if key not in cache:
            cache[key] = _from_metadata(src)
        if cache[key]:
            return cache[key], "metadata"
    start = (doc.get("event") or {}).get("start")         # ISO, meist UTC („…Z“)
    if start:
        try:
            return datetime.fromisoformat(str(start).replace("Z", "+00:00")).astimezone().strftime("%Y-%m-%d %H:%M"), "event"
        except ValueError:
            pass
    m = re.match(r"(\d{4}-\d{2}-\d{2})[ _](\d{2})-(\d{2})", src.name)
    if m:
        return f"{m[1]} {m[2]}:{m[3]}", "name"
    # einstellbares Datumsformat der App (RecordingName): „261030 1403 …“, „20261030 1403 …“
    m = re.match(r"(?:(?:Aufnahme|Recording) )?(\d{2}|\d{4})(\d{2})(\d{2})[ _.-](\d{2})(\d{2})\b", src.name)
    if m:
        y = m[1] if len(m[1]) == 4 else "20" + m[1]
        with contextlib.suppress(ValueError):
            return datetime(int(y), int(m[2]), int(m[3]), int(m[4]), int(m[5])).strftime("%Y-%m-%d %H:%M"), "name"
    return doc.get("created"), "transcript"


def entries(root=None):
    root = Path(root or config.load()["watch_dir"]).expanduser()
    try:
        cache = json.loads(CACHE.read_text())
    except (OSError, ValueError):
        cache = {}
    size = len(cache)
    out = []
    for jp in sorted(root.rglob("*.transcript.json")) if root.exists() else []:
        if any(p.startswith(".") for p in jp.relative_to(root).parts):
            continue
        try:
            doc = json.loads(jp.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        src = Path(doc.get("source") or "")
        sp = summarize.summary_path(jp)
        meta = summarize.read_meta(sp)
        when, origin = recorded(doc, src, cache)
        # zuletzt bearbeitet: Benennen, Bestätigen, Glossar, Umbenennen schreiben das Transkript neu
        activity = max([jp.stat().st_mtime] + ([sp.stat().st_mtime] if meta else []))
        speakers = doc.get("speakers", [])
        readable, _ = render.find_readable(jp.with_name(jp.name.removesuffix(".transcript.json")), src.name)
        out.append({
            "transcript": str(jp), "readable": str(readable) if readable else None,
            "title": jp.name.removesuffix(".transcript.json"),
            "folder": str(jp.parent.relative_to(root)) if jp.parent != root else "",
            "source": str(src), "audio": src.is_file(), "audio_bytes": src.stat().st_size if src.is_file() else 0,
            "recorded": when, "recorded_from": origin, "activity": _local(activity), "activity_ts": activity,
            "duration": doc.get("duration", 0), "event": (doc.get("event") or {}).get("title"),
            "speakers": list(dict.fromkeys(s.get("display") for s in sorted(speakers, key=lambda s: -s.get("speech_s", 0)))),
            "open": sum(1 for s in speakers if s.get("status") in OPEN and s.get("speech_s", 0) >= 15),
            "summary": meta.get("name") if meta else None,
        })
    if len(cache) != size:
        try:
            CACHE.write_text(json.dumps(cache, ensure_ascii=False))
        except OSError:
            pass
    return out
