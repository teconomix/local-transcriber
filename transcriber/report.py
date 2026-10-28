"""Fehlerbericht: alles, was zur Fehlersuche hilft, in eine ZIP-Datei – ohne Aufnahmen, Transkripte, Stimmdatenbank,
Glossar. Die App ruft `transcriber report` auf, legt ihre macOS-Infos (Freigaben, Audiogeräte, Einstellungen) als
JSON dazu und hängt die ZIP-Datei an eine Mail an info@teconomix.net (2026-10-14).

Unkenntlich (Standard): Datei- und Ordnernamen aus ~/Transcriber, Termintitel und Teilnehmer aus .event.json und
.transcript.json, Sprechernamen, Namen aus der Stimmdatenbank, E-Mail-Adressen, Benutzername und Home-Pfad werden durch
Platzhalter ersetzt (‹Datei 3›, ‹Person 2› …).
Gleicher Name → gleicher Platzhalter, damit Abläufe im Protokoll lesbar bleiben."""
import contextlib
import json
import platform
import re
import shutil
import sqlite3
import subprocess
import sys
import time
import zipfile
from importlib import metadata
from pathlib import Path

from . import config
from .summarize import PARTICLES

LOGS = ("app.log", "watch.log", "dictate.log")
TAIL = 2000                    # Zeilen je Protokoll
AUDIO = config.MEDIA_EXT


class Redactor:
    """Ersetzt bekannte vertrauliche Zeichenketten durch stabile Platzhalter."""

    def __init__(self, enabled=True):
        self.enabled = enabled
        self.map = {}          # Text → Platzhalter
        self.count = {}

    def add(self, text, kind):
        text = (text or "").strip()
        if self.enabled and len(text) >= 3 and text not in self.map:
            self.count[kind] = self.count.get(kind, 0) + 1
            self.map[text] = f"‹{kind} {self.count[kind]}›"

    def __call__(self, s):
        if not self.enabled or not s:
            return s
        s = re.sub(r"[\w.+-]+@[\w-]+(\.[\w-]+)+", "‹E-Mail›", s)
        if self.map:
            # Nur ganze Wörter (sonst würde „Kurz“ in „Kurzfassung“ ersetzt); längste zuerst („Termin X, Tag 1“ vor „Termin X“).
            alt = "|".join(re.escape(t) for t in sorted(self.map, key=len, reverse=True))
            s = re.sub(rf"(?<!\w)(?:{alt})(?!\w)", lambda m: self.map[m.group(0)], s)
        return s


def _person(red, n):
    """Ganzer Name und seine Teile (ab 3 Zeichen, ohne „von“, „der“ …: die stehen auch in gewöhnlichen Meldungen)."""
    red.add(n, "Person")
    for part in (n or "").split():
        if len(part) >= 3 and part.lower() not in PARTICLES:
            red.add(part, "Name")


def _event(red, ev):
    red.add(ev.get("title"), "Termin")
    red.add(ev.get("calendar"), "Kalender")
    for a in ev.get("attendees", []):
        _person(red, a.get("name"))


def _db_rows(sql):
    """Zeilen aus der Stimmdatenbank (nur lesend; fehlt sie, keine)."""
    with contextlib.suppress(Exception), contextlib.closing(sqlite3.connect(f"file:{config.DB}?mode=ro", uri=True)) as db:
        return db.execute(sql).fetchall()
    return []


def _folder(red, part, exclude):
    if part not in exclude and re.search(r"[^\W\d_]", part):   # ohne Buchstaben („2026“) wie in jedem Zeitstempel
        red.add(part, "Ordner")


def _names(red, watch_dir, exclude=()):
    """Vertrauliche Zeichenketten sammeln: Datei- und Ordnernamen, Termine, Personen, Benutzer.
    exclude: Ordnernamen der App („Aufnahmen“) – nicht vertraulich, und als Wort in Meldungen nötig."""
    import getpass
    home = str(Path.home())
    if watch_dir.exists():
        for f in watch_dir.rglob("*"):
            if f.is_dir():
                for part in f.relative_to(watch_dir).parts:
                    _folder(red, part, exclude)
                continue
            if f.is_file() and (f.suffix.lower() in AUDIO or f.name.endswith(".transcript.json")):
                stem = f.name.removesuffix(".transcript.json") if f.name.endswith(".transcript.json") else f.stem
                red.add(stem, "Datei")
            if f.name.endswith((".event.json", ".transcript.json")):
                try:
                    d = json.loads(f.read_text())
                except (OSError, ValueError):
                    continue
                if f.name.endswith(".event.json"):
                    _event(red, d)
                    continue
                _event(red, d.get("event") or {})
                for c in d.get("speakers", []):
                    _person(red, c.get("name"))
    for (n,) in _db_rows("SELECT name FROM persons"):
        _person(red, n)
    # Auch Titel gelöschter oder umbenannter Aufnahmen, die nur noch im Protokoll stehen (Wächter: de und en)
    pats = [(r"Aufnahme benannt in [\d.]+ s: (.+?)\.\w+$", "Datei"), (r"Termin zur Aufnahme: (.+) \(\d+ Teilnehmer\)$", "Termin"),
            (r"Aufnahme (?:gestartet|beendet): (.+?)\.m4a", "Datei"), (r"→ (.+?)\.\w+$", "Datei"),
            (r"(?:fertig|done): (.+?)\.(?:md|txt|json) ", "Datei"),
            (r"gelöscht(?:, Transkript bleibt)?: (.+?)\.\w+$", "Datei"),   # seit 2026-10-20 mit Namen; Datei gibt es nicht mehr
            (r"↪ (.+?)\.\w+: ", "Datei"), (r"(?:FEHLER, siehe|ERROR, see) (.+?)\.error\.txt", "Datei")]
    for name in LOGS:
        t = _tail(config.DATA / name) or ""
        for line in t.splitlines():
            for p, kind in pats:
                if m := re.search(p, line):
                    red.add(m.group(1), kind)
            if m := re.search(r"(?:überwache|watching) (/.+)$", line):   # anderer Wächterordner (--dir, alte Einstellung)
                for part in Path(m.group(1)).parts[1:]:
                    if part not in Path(home).parts + ("Volumes",):
                        _folder(red, part, exclude)
    # Aufträge außerhalb des Wächterordners (CLI, MCP) stehen nur in den Statusdateien bzw. der Datenbank
    for f in config.JOBS.glob("*.json") if config.JOBS.exists() else []:
        with contextlib.suppress(OSError, ValueError):
            red.add(Path(json.loads(f.read_text()).get("source") or "").stem, "Datei")
    for (src,) in _db_rows("SELECT source FROM jobs"):
        red.add(Path(src or "").stem, "Datei")
    user = getpass.getuser()
    if red.enabled:
        red.map[home] = "~"
        red.add(user, "Benutzer")


def _tail(path, n=TAIL):
    try:
        lines = path.read_text(errors="replace").splitlines()
    except OSError:
        return None
    return "\n".join(lines[-n:]) + "\n"


def _core_info():
    """Umgebung des Python-Kerns: Versionen, Modelle, Platz – keine Inhalte."""
    pkgs = {}
    for p in ("transcriber", "mlx", "mlx-whisper", "pyannote.audio", "torch", "numpy", "soundfile", "mcp"):
        try:
            pkgs[p] = metadata.version(p)
        except metadata.PackageNotFoundError:
            pkgs[p] = None
    hf = Path("~/.cache/huggingface/hub").expanduser()
    models = sorted(p.name for p in hf.glob("models--*")) if hf.exists() else []
    local = sorted(p.name for p in (config.DATA / "models").glob("*")) if (config.DATA / "models").exists() else []
    ffmpeg = shutil.which("ffmpeg") or (str(config.DATA / "bin" / "ffmpeg") if (config.DATA / "bin" / "ffmpeg").exists() else None)
    persons = (_db_rows("SELECT count(*) FROM persons") or [(None,)])[0][0]
    refs = (_db_rows("SELECT count(*) FROM embeddings") or [(None,)])[0][0]
    du = shutil.disk_usage(Path.home())
    return {"python": sys.version.split()[0], "platform": platform.platform(), "machine": platform.machine(),
            "packages": pkgs, "hf_models": models, "local_models": local, "ffmpeg": ffmpeg,
            "config": config.load(), "config_file": config.CONFIG.exists(),
            "voice_db": {"persons": persons, "references": refs},          # nur Anzahlen
            "disk_free_gb": round(du.free / 1e9, 1), "data_dir": str(config.DATA)}


def build(out, description="", app_info=None, redact=True):
    """ZIP-Datei schreiben; liefert die Liste der enthaltenen Dateien."""
    cfg = config.load()
    watch_dir = Path(cfg["watch_dir"]).expanduser()
    red = Redactor(redact)
    _names(red, watch_dir, cfg.get("watch_exclude", []))
    files = {}
    head = [f"Transcriber-Fehlerbericht vom {time.strftime('%Y-%m-%d %H:%M')}",
            f"Dateinamen/Termintitel unkenntlich: {'ja' if redact else 'nein'}", "", "Beschreibung:", description.strip() or "–", ""]
    files["bericht.txt"] = red("\n".join(head))
    files["kern.json"] = red(json.dumps(_core_info(), ensure_ascii=False, indent=1, default=str))
    if app_info:
        files["app.json"] = red(json.dumps(app_info, ensure_ascii=False, indent=1, default=str))
    for name in LOGS:
        t = _tail(config.DATA / name)
        if t is not None:
            files[f"protokolle/{name}"] = red(t)
    for i, f in enumerate(sorted(config.JOBS.glob("*.json"), key=lambda p: p.stat().st_mtime)[-15:]):
        files[f"auftraege/{i + 1:02d}.json"] = red(f.read_text(errors="replace"))
    errs = sorted(watch_dir.rglob("*.error.txt"), key=lambda p: p.stat().st_mtime)[-5:] if watch_dir.exists() else []
    for i, f in enumerate(errs):
        files[f"fehler/{i + 1:02d}.txt"] = red(f"{f.name}\n\n{f.read_text(errors='replace')}")
    try:                      # startet der Kern, sind die Modelle offline ladbar? (ohne sie zu laden)
        r = subprocess.run([sys.executable, "-c", "import mlx_whisper, pyannote.audio; print('ok')"],
                           capture_output=True, text=True, timeout=120)
        files["kern-import.txt"] = red(r.stdout + r.stderr[-4000:])
    except Exception as e:
        files["kern-import.txt"] = red(str(e))
    out = Path(out).expanduser()
    out.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        for name, text in files.items():
            z.writestr(name, text)
    return sorted(files)
