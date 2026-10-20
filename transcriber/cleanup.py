"""Löschen und Aufräumen (seit 0.8).

- delete(): eine Aufnahme ganz („Alles“) oder nur ihr Audio („Nur Aufnahme“, Transkript bleibt).
- cleanup(): nach Löschen im Finder aufräumen; auf Wunsch Audio im Aufnahmeordner nach N Tagen löschen.

Sichtbare Dateien (Audio, Transkript, Begleitdateien) kommen in den Papierkorb – ein Versehen lässt sich rückgängig
machen. Was nur Transcriber kennt, wird endgültig entfernt: der Zwischenspeicher (enthält Kopien des Audios), die
Statusdateien der App und die Einträge der Stimmdatenbank. Björns Entscheidung 2026-10-20: „Nur Aufnahme“ behält
Transkript, Stimm-Fingerabdrücke und den Eintrag in der App; „Alles“ entfernt auch die Stimmen aus diesem Gespräch.
Anlass: Im Finder gelöscht, blieben Eintrag, drei WAV-Kopien und die Stimmdaten zurück."""
import json
import os
import re
import shutil
import subprocess
import time
from pathlib import Path

from . import config, pipeline, render, speakers
from .i18n import t as tr

AUDIO_EXT = {".m4a", ".mp3", ".wav", ".aac", ".flac", ".ogg", ".opus", ".mp4", ".mov", ".m4v", ".mkv", ".webm", ".caf",
             ".aiff", ".aif"}
RECORDINGS = ("Aufnahmen", "Recordings")        # Aufnahmeordner der App in watch_dir (wie recordingsDir in der App)


def trash(p):
    """In den Papierkorb (macOS 15+: /usr/bin/trash, dann geht „Zurücklegen“; sonst nach ~/.Trash verschieben).
    TRANSCRIBER_TRASH = anderer Ordner (Tests). Liefert True, wenn die Datei weg ist."""
    p = Path(p)
    if not p.exists():
        return False
    target = os.environ.get("TRANSCRIBER_TRASH")
    if not target and Path("/usr/bin/trash").exists():
        if subprocess.run(["/usr/bin/trash", str(p)], capture_output=True).returncode == 0 and not p.exists():
            return True
    d = Path(target).expanduser() if target else Path.home() / ".Trash"
    d.mkdir(parents=True, exist_ok=True)
    dest, n = d / p.name, 2
    while dest.exists():
        dest = d / f"{p.stem} {n}{p.suffix}"; n += 1
    shutil.move(str(p), str(dest))
    return True


def _transcript_files(jp, src):
    """Transkript-Dateien einer Aufnahme: .transcript.json, das eigene lesbare (.txt/.md, nie eine fremde gleichen
    Namens – render.is_ours), .srt, .error.txt, .event.json."""
    stem = jp.parent / jp.name.removesuffix(".transcript.json")
    readable, _ = render.find_readable(stem, src.name)
    out = [p for p in [jp, readable] if p and p.exists()]
    for base in {stem, src.with_suffix("")}:                       # Begleitdateien liegen neben Transkript bzw. Audio
        out += [base.with_name(base.name + e) for e in pipeline.SIDECARS if base.with_name(base.name + e).exists()]
    return list(dict.fromkeys(out))


def _status_files(src):
    out = []
    for f in config.JOBS.glob("*.json"):
        try:
            if json.loads(f.read_text()).get("source") == str(src):
                out.append(f)
        except (OSError, ValueError):
            continue
    return out


def _forget(db, jid):
    """Stimmdatenbank: Auftrag, Stimm-Fingerabdrücke (clusters) und gelernte Referenzen (embeddings) dieses Gesprächs;
    Personen, auf die danach nichts mehr verweist (keine Referenz, kein bestätigter Sprecher einer anderen Aufnahme –
    bei wenig Sprechzeit gibt es nur Letzteres), auch. Liefert die Zahl entfernter Referenzen."""
    with db:
        n = db.execute("DELETE FROM embeddings WHERE job_id=?", (jid,)).rowcount
        db.execute("DELETE FROM clusters WHERE job_id=?", (jid,))
        db.execute("DELETE FROM jobs WHERE id=?", (jid,))
        db.execute("DELETE FROM persons WHERE id NOT IN (SELECT person_id FROM embeddings) "
                   "AND id NOT IN (SELECT person_id FROM clusters WHERE person_id IS NOT NULL)")
    return n


def _locked(src, jp):
    return any(p.with_name(p.name + ".lock").exists() for p in
               {src.with_suffix(""), jp.parent / jp.name.removesuffix(".transcript.json")} if p)


def delete(path, audio_only=False):
    """Aufnahme löschen. path: Audio, .transcript.json oder lesbares Transkript. Liefert, was weg ist."""
    p = Path(path).expanduser().resolve()
    try:
        doc, jp = pipeline.load_doc(p)
    except (OSError, ValueError):
        doc, jp = None, None
    src = Path(doc["source"]) if doc else p
    if not doc and p.suffix.lower() not in AUDIO_EXT:
        raise FileNotFoundError(tr("Weder Aufnahme noch Transkript gefunden: ", "Neither recording nor transcript found: ") + str(p))
    if _locked(src, jp or src):
        raise RuntimeError(tr("Transkription dieser Datei läuft noch", "transcription of this file is still running"))
    db = speakers.connect()
    jid = doc["job_id"] if doc else None
    if not jid:
        r = db.execute("SELECT id FROM jobs WHERE source=?", (str(src),)).fetchone()
        jid = r["id"] if r else (pipeline.job_id(src) if src.exists() else None)
    gone = []
    if trash(src):
        gone.append(str(src))
    cache = config.CACHE / jid if jid else None
    had_cache = bool(cache and cache.exists())
    if had_cache:
        shutil.rmtree(cache, ignore_errors=True)
    voices = 0
    if not audio_only:
        for f in (_transcript_files(jp, src) if jp else []):
            if trash(f):
                gone.append(str(f))
        if jid:
            voices = _forget(db, jid)
        for f in _status_files(src):
            f.unlink(missing_ok=True)
    return {"trashed": gone, "cache": had_cache, "voices": voices, "audio_only": audio_only, "job_id": jid}


_JOB_ID = re.compile(r'"job_id":\s*"([0-9a-f]+)"')


def _find_transcript(jid, roots):
    """Transkript eines Auftrags anderswo (im Finder verschoben): job_id steht am Anfang jeder .transcript.json."""
    for root in roots:
        for f in Path(root).rglob("*.transcript.json"):
            try:
                with open(f, encoding="utf-8") as h:
                    m = _JOB_ID.search(h.read(400))
            except OSError:
                continue
            if m and m.group(1) == jid:
                return f
    return None


def cleanup(audio_days=None, now=None, dry_run=False):
    """Aufräumen. (1) Im Finder gelöscht: fehlt nur das Audio → Zwischenspeicher weg; fehlen Audio und Transkript →
    wie „Alles“ (Zwischenspeicher, Stimmdatenbank, Eintrag). Vorsicht: nur, wenn der Ordner der Datei noch da ist (sonst
    ist eher ein Laufwerk abgemeldet) und das Transkript nicht verschoben unter watch_dir liegt (dann nur Pfad nachziehen).
    (2) audio_days: Audio im Aufnahmeordner, das fertig transkribiert und älter ist, wie „Nur Aufnahme“ löschen.
    dry_run: nur auflisten (out["plan"]), nichts ändern. Liefert eine Zusammenfassung."""
    now = now or time.time()
    cfg = config.load()
    watch = Path(cfg["watch_dir"]).expanduser()
    db = speakers.connect()
    out = {"cache": 0, "forgotten": 0, "relinked": 0, "audio_deleted": [], "plan": []}
    for r in db.execute("SELECT id, source, transcript FROM jobs").fetchall():
        jid, src = r["id"], Path(r["source"] or "")
        jp = Path(r["transcript"]) if r["transcript"] else None
        if src.exists() or not src.parent.exists():
            continue
        if jp and jp.exists():                               # Audio weg, Transkript da: nur die Audio-Kopien
            if dry_run:
                out["plan"] += [f"cache {jid} ({src.name})"] if (config.CACHE / jid).exists() else []
                continue
            if (config.CACHE / jid).exists():
                shutil.rmtree(config.CACHE / jid, ignore_errors=True); out["cache"] += 1
            continue
        if jp and not jp.parent.exists():
            continue
        moved = _find_transcript(jid, [watch]) if watch.exists() else None
        if dry_run:
            out["plan"].append(f"{'relink' if moved else 'vergessen'} {jid} ({src.name})")
            continue
        if moved:
            with db:
                db.execute("UPDATE jobs SET transcript=? WHERE id=?", (str(moved), jid))
            out["relinked"] += 1
            continue
        if (config.CACHE / jid).exists():
            shutil.rmtree(config.CACHE / jid, ignore_errors=True); out["cache"] += 1
        _forget(db, jid)
        for f in _status_files(src):
            f.unlink(missing_ok=True)
        out["forgotten"] += 1
    if audio_days:
        limit = now - audio_days * 86400
        for d in (watch / n for n in RECORDINGS):
            if not d.is_dir():
                continue
            for a in d.iterdir():
                if a.name.startswith(".") or a.suffix.lower() not in AUDIO_EXT or a.stat().st_mtime > limit:
                    continue
                jp = a.with_name(a.stem + ".transcript.json")
                if not jp.exists() or a.with_name(a.stem + ".lock").exists():
                    continue                                 # nur fertig transkribierte Aufnahmen
                if dry_run:
                    out["plan"].append(f"audio {a.name}")
                    continue
                try:
                    delete(jp, audio_only=True)
                    out["audio_deleted"].append(str(a))
                except (OSError, RuntimeError, ValueError):
                    continue
    return out
