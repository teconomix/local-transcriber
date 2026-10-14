"""Überwachter Ordner: neue Audio-/Videodateien werden transkribiert, Ergebnis landet daneben.

Abfrage alle 5 s (kein zusätzliches Paket nötig). Eine Datei gilt als fertig kopiert, wenn sich Größe und
Änderungszeit 10 s lang nicht ändern. Erledigt = <name>.transcript.json existiert und ist neuer als die Datei.
Dateien mit <name>.lock (laufender Auftrag) werden übersprungen. Fehlschläge werden in <name>.error.txt notiert und erst nach Änderung der Datei erneut versucht.

Den Aufnahmeordner der App (oberste Ebene „Aufnahmen“/„Recordings“, config „watch_exclude“) transkribiert der Wächter
nicht – dort startet die App selbst, und ihre Einstellung „Transkribieren“ soll gelten (2026-10-12). Überall gilt:
eine im Finder umbenannte oder verschobene Datei bekommt ihr vorhandenes Transkript nachgezogen (pipeline.adopt)."""
import time
import traceback
from pathlib import Path

from . import config
from .i18n import t

EXT = {".m4a", ".mp3", ".wav", ".aac", ".flac", ".ogg", ".opus", ".mp4", ".mov", ".m4v", ".mkv", ".webm", ".caf", ".aiff", ".aif"}


def _pending(d):
    for f in sorted(d.rglob("*")):
        if f.suffix.lower() not in EXT or f.name.startswith(".") or not f.is_file():
            continue
        done = f.with_name(f.stem + ".transcript.json")
        err = f.with_name(f.stem + ".error.txt")
        mt = f.stat().st_mtime
        lock = f.with_name(f.stem + ".lock")
        if (done.exists() and done.stat().st_mtime >= mt) or (err.exists() and err.stat().st_mtime >= mt):
            continue
        if lock.exists() and time.time() - lock.stat().st_mtime < 6 * 3600:  # läuft gerade woanders
            continue
        yield f


def run(dir_=None, interval=5, settle=10):
    from . import pipeline
    cfg = config.load()
    d = Path(dir_ or cfg["watch_dir"]).expanduser()
    d.mkdir(parents=True, exist_ok=True)
    print(t("überwache", "watching") + f" {d}", flush=True)
    seen = {}
    while True:
        for f in _pending(d):
            st = f.stat()
            sig = (st.st_size, st.st_mtime)
            if seen.get(f) != sig:
                seen[f] = sig; seen[(f, "t")] = time.time(); continue
            if time.time() - seen[(f, "t")] < settle:
                continue
            if f.relative_to(d).parts[0] in cfg.get("watch_exclude", []):
                if seen.get((f, "x")) == sig:        # schon geprüft, kein umbenanntes Transkript: nicht ständig hashen
                    continue
                seen[(f, "x")] = sig
                try:
                    if pipeline.adopt(f):
                        print(f"{time.strftime('%H:%M:%S')} ↪ {f.name}: " + t("umbenannt, Transkript nachgezogen", "renamed, transcript moved along"), flush=True)
                except Exception:
                    print(f"{time.strftime('%H:%M:%S')} ↪ {f.name}: " + traceback.format_exc(), flush=True)
                continue
            print(f"{time.strftime('%H:%M:%S')} → {f.name}", flush=True)
            try:
                doc, paths = pipeline.run(f, cfg=cfg)
                print("   " + t("fertig", "done") + f": {paths.get('md', paths['json']).name}  "
                      + ", ".join(f"{c['display']}" for c in doc["speakers"]), flush=True)
            except Exception:
                f.with_name(f.stem + ".error.txt").write_text(traceback.format_exc())
                print("   " + t("FEHLER, siehe", "ERROR, see") + f" {f.stem}.error.txt", flush=True)
            seen.pop(f, None)
        time.sleep(interval)
