"""Löschen und Aufräumen (seit 0.8).

- delete(): eine Aufnahme ganz („Alles“) oder nur ihr Audio („Nur Aufnahme“, Transkript bleibt).
- cleanup(): nach Löschen im Finder aufräumen; auf Wunsch Audio und Video in ~/Transcriber N Tage nach dem Transkript löschen.

Sichtbare Dateien (Audio, Transkript, Begleitdateien) kommen in den Papierkorb – ein Versehen lässt sich rückgängig
machen. Was nur Transcriber kennt, wird endgültig entfernt: der Zwischenspeicher (enthält Kopien des Audios), die
Statusdateien der App und die Einträge der Stimmdatenbank. Björns Entscheidung 2026-10-20: „Nur Aufnahme“ behält
Transkript, Stimm-Fingerabdrücke und den Eintrag in der App; „Alles“ entfernt auch die Stimmen aus diesem Gespräch.
Anlass: Im Finder gelöscht, blieben Eintrag, drei WAV-Kopien und die Stimmdaten zurück."""
import fcntl
import json
import os
import re
import shutil
import subprocess
import time
from pathlib import Path

from . import config, pipeline, render, speakers
from .i18n import t as tr

AUDIO_EXT = config.MEDIA_EXT


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


def _status_by_source():
    out = {}
    for f in config.JOBS.glob("*.json"):
        try:
            s = json.loads(f.read_text()).get("source")
            out.setdefault(str(Path(s).resolve()) if s else None, []).append(f)   # aufgelöst: /var ↔ /private/var
        except (OSError, ValueError):
            continue
    return out


def _status_files(src):
    return _status_by_source().get(str(Path(src).resolve()), [])


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


def _locks(src, jp):
    return [p.with_name(p.name + ".lock") for p in {src.with_suffix(""), jp.parent / jp.name.removesuffix(".transcript.json")}
            if p.with_name(p.name + ".lock").exists()]


def _lock_alive(f):
    """<name>.lock enthält die PID des Auftrags (pipeline.run). Rest eines abgebrochenen Laufs = Prozess weg."""
    try:
        os.kill(int(f.read_text().strip()), 0)
    except (PermissionError, ValueError):                 # Prozess eines anderen Benutzers bzw. unlesbar: lieber „läuft“
        return True
    except OSError:
        return False
    return True


def _locked(src, jp):
    return any(_lock_alive(f) for f in _locks(src, jp))


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
        # ohne Transkript (Auftrag fehlgeschlagen): trotzdem die Begleitdateien neben der Quelle (.error.txt, .event.json)
        base = src.with_suffix("")
        files = _transcript_files(jp, src) if jp else [base.with_name(base.name + e) for e in pipeline.SIDECARS]
        for f in files:
            if trash(f):
                gone.append(str(f))
        for f in _locks(src, jp or src):                      # Reste abgebrochener Läufe (_locked hat geprüft)
            f.unlink(missing_ok=True)
        if jid:
            voices = _forget(db, jid)
        for f in _status_files(src):
            f.unlink(missing_ok=True)
    return {"trashed": gone, "cache": had_cache, "voices": voices, "audio_only": audio_only, "job_id": jid}


_JOB_ID = re.compile(r'"job_id":\s*"([0-9a-f]+)"')


def _transcripts_by_job(root):
    """Transkripte unter root nach job_id (im Finder verschoben): job_id steht am Anfang jeder .transcript.json."""
    out = {}
    for f in Path(root).rglob("*.transcript.json") if Path(root).is_dir() else []:
        if f.is_symlink():
            continue
        try:
            with open(f, encoding="utf-8") as h:
                m = _JOB_ID.search(h.read(400))
        except OSError:
            continue
        if m:
            out.setdefault(m.group(1), f)
    return out


def _reachable(p, watch):
    """Darf das Fehlen von p als „gelöscht“ gelten? /Volumes/<name>/…: nur bei eingehängtem Laufwerk (auch für Dateien
    direkt im Wurzelordner). Unter watch_dir zählt auch ein fehlender Unterordner als gelöscht; sonst muss der Ordner
    der Datei da sein (fehlt er, ist eher ein Laufwerk abgemeldet)."""
    parts = p.parts
    if len(parts) > 2 and parts[1] == "Volumes" and not os.path.ismount(os.path.realpath(Path("/Volumes", parts[2]))):
        return False
    if watch.is_dir() and p.is_relative_to(watch):
        return True
    return p.parent.exists()


def _orphan_caches(db, now, dry_run):
    """Zwischenspeicher ohne Eintrag in der Datenbank (abgebrochene/fehlgeschlagene Aufträge), älter als 1 Tag. Nur,
    wenn gerade keine Transkription läuft (run.lock frei; sie legt ihren Zwischenspeicher vor dem Eintrag an)."""
    if not config.CACHE.is_dir():
        return []
    known = {r[0] for r in db.execute("SELECT id FROM jobs")}
    out = []
    with open(config.DATA / "run.lock", "a") as lk:
        try:
            fcntl.flock(lk, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return []
        for d in config.CACHE.iterdir():
            if d.name in known or d.is_symlink() or not d.is_dir():
                continue
            try:
                newest = max([d.stat().st_mtime] + [f.stat().st_mtime for f in d.iterdir()])
            except OSError:
                continue
            if now - newest < 86400:
                continue
            out.append(d.name)
            if not dry_run:
                shutil.rmtree(d, ignore_errors=True)
    return out


def cleanup(audio_days=None, now=None, dry_run=False):
    """Aufräumen (die App alle 10 min). (1) Im Finder gelöscht: fehlt nur das Audio → Zwischenspeicher weg; fehlen Audio
    und Transkript → Zwischenspeicher und Eintrag in der App weg, die Stimmdatenbank bleibt (Björn 2026-10-28: das
    Transkript kann auch nur archiviert sein; Stimmen entfernt „Alles löschen“ oder das Fenster „Stimmen“). Vorsicht: nichts bei
    abgemeldetem Laufwerk (_reachable); liegt das Transkript verschoben unter watch_dir, nur den Pfad nachziehen.
    (2) audio_days: Audio- und Videodateien in watch_dir samt Unterordnern, deren Transkript älter ist, wie
    „Nur Aufnahme“ löschen (seit 0.10 der ganze Ordner, vorher nur der Aufnahmeordner der App).
    (3) Verwaiste Zwischenspeicher (_orphan_caches).
    dry_run: nur auflisten (out["plan"]), nichts ändern. Liefert eine Zusammenfassung."""
    now = now or time.time()
    cfg = config.load()
    watch = Path(cfg["watch_dir"]).expanduser()
    db = speakers.connect()
    out = {"cache": 0, "forgotten": 0, "relinked": 0, "audio_deleted": [], "plan": []}
    index = states = None                                    # Transkripte unter watch_dir nach job_id, Statusdateien: bei Bedarf
    for r in db.execute("SELECT id, source, transcript FROM jobs").fetchall():
        jid, src = r["id"], Path(r["source"] or "")
        jp = Path(r["transcript"]) if r["transcript"] else None
        if src.exists() or not _reachable(src, watch):
            continue
        if jp and jp.exists():                               # Audio weg, Transkript da: nur die Audio-Kopien
            if dry_run:
                out["plan"] += [f"cache {jid} ({src.name})"] if (config.CACHE / jid).exists() else []
                continue
            if (config.CACHE / jid).exists():
                shutil.rmtree(config.CACHE / jid, ignore_errors=True); out["cache"] += 1
            continue
        if jp and not _reachable(jp, watch):
            continue
        if index is None:
            index, states = _transcripts_by_job(watch), _status_by_source()
        moved = index.get(jid)
        status = states.get(str(src.resolve()), [])
        cache = (config.CACHE / jid).exists()
        if dry_run:
            if moved or cache or status:
                out["plan"].append(f"{'relink' if moved else 'aufräumen'} {jid} ({src.name})")
            continue
        if moved:
            with db:
                db.execute("UPDATE jobs SET transcript=? WHERE id=?", (str(moved), jid))
            out["relinked"] += 1
            continue
        if cache:
            shutil.rmtree(config.CACHE / jid, ignore_errors=True); out["cache"] += 1
        for f in status:                                     # Stimmdaten bleiben (Björn 2026-10-28)
            f.unlink(missing_ok=True)
        if cache or status:                                  # Eintrag bleibt in der Datenbank: nur einmal zählen
            out["forgotten"] += 1
    if audio_days and watch.is_dir():
        limit = now - audio_days * 86400
        for a in sorted(watch.rglob("*")):
            if (a.suffix.lower() not in AUDIO_EXT or a.is_symlink() or not a.is_file()
                    or any(p.startswith(".") for p in a.relative_to(watch).parts)):
                continue
            jp = a.with_name(a.stem + ".transcript.json")
            if not jp.exists() or a.with_name(a.stem + ".lock").exists():
                continue                                     # nur fertig transkribierte Aufnahmen
            if _transcribed_at(jp) > limit:
                continue
            try:                                             # gehört das Transkript zu genau dieser Datei?
                doc = json.loads(jp.read_text())
                if Path(doc["source"]).resolve() != a.resolve():
                    continue
                # und zu diesem Inhalt? Neue Datei mit wiederverwendetem Namen („Neue Aufnahme.m4a“, „ZOOM0001.WAV“)
                # und altem Originaldatum hätte sonst das alte Transkript – Hash nur für Löschkandidaten
                if pipeline.job_id(a) != doc["job_id"]:
                    continue
            except (OSError, ValueError, KeyError):
                continue
            if dry_run:
                out["plan"].append(f"audio {a.name}")
                continue
            try:
                delete(jp, audio_only=True)
                out["audio_deleted"].append(str(a))
            except (OSError, RuntimeError, ValueError):
                continue
    orphans = _orphan_caches(db, now, dry_run)
    if dry_run:
        out["plan"] += [f"cache {d} (verwaist)" for d in orphans]
    else:
        out["cache"] += len(orphans)
    return out


def _transcribed_at(jp):
    """Zeitpunkt des Transkripts („created“, steht vorn in der Datei), sonst Änderungszeit der .transcript.json.
    Nicht das Datum der Audiodatei: AirDrop, Finder und Syncthing behalten das Originaldatum – eine alte Aufnahme,
    die heute in den Ordner kommt, wäre sonst gleich nach dem Transkribieren wieder weg."""
    try:
        with open(jp, encoding="utf-8", errors="replace") as f:
            m = re.search(r'"created":\s*"(\d{4}-\d{2}-\d{2} \d{2}:\d{2})"', f.read(4096))
        if m:
            return time.mktime(time.strptime(m.group(1), "%Y-%m-%d %H:%M"))
    except OSError:
        pass
    return jp.stat().st_mtime
