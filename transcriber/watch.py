"""Überwachter Ordner: neue Audio-/Videodateien werden transkribiert, Ergebnis landet daneben.

Abfrage alle 5 s (kein zusätzliches Paket nötig). Eine Datei gilt als fertig kopiert, wenn sich Größe und
Änderungszeit 10 s lang nicht ändern. Erledigt = <name>.transcript.json existiert und ist neuer als die Datei.
Dateien mit <name>.lock (laufender Auftrag) werden übersprungen. Fehlschläge werden in <name>.error.txt notiert und erst nach Änderung der Datei erneut versucht.

Den Aufnahmeordner der App (oberste Ebene „Aufnahmen“/„Recordings“, config „watch_exclude“) transkribiert der Wächter
nicht – dort startet die App selbst, und ihre Einstellung „Transkribieren“ soll gelten (2026-10-12). Überall gilt:
eine im Finder umbenannte oder verschobene Datei bekommt ihr vorhandenes Transkript nachgezogen (pipeline.adopt).

Ändert sich der Kern (Update, git), startet sich der Wächter zwischen zwei Aufträgen selbst neu (os.execv) – vorher
lief er nach Änderungen tagelang mit altem Code weiter (2026-10)."""
import os
import sys
import time
import traceback
from pathlib import Path

from . import config
from .i18n import t

EXT = config.MEDIA_EXT


def _pending(d):
    """Liste (kein Generator): während eines langen Auftrags verschwundene Dateien bringen den Wächter nicht zu Fall."""
    out = []
    for f in sorted(d.rglob("*")):
        if f.suffix.lower() not in EXT or f.name.startswith(".") or f.is_symlink() or not f.is_file():
            continue
        done = f.with_name(f.stem + ".transcript.json")
        err = f.with_name(f.stem + ".error.txt")
        lock = f.with_name(f.stem + ".lock")
        try:
            mt = f.stat().st_mtime
            if (done.exists() and done.stat().st_mtime >= mt) or (err.exists() and err.stat().st_mtime >= mt):
                continue
            if lock.exists() and time.time() - lock.stat().st_mtime < 6 * 3600:  # läuft gerade woanders
                continue
        except OSError:                                  # inzwischen gelöscht/verschoben
            continue
        out.append(f)
    return out


def _code_stamp():
    """Stand des Kerns: Anzahl und jüngste Änderungszeit der .py-Dateien des Pakets."""
    fs = list(Path(__file__).parent.rglob("*.py"))
    return len(fs), max((f.stat().st_mtime for f in fs), default=0)


def run(dir_=None, interval=5, settle=10):
    from . import pipeline
    cfg = config.load()
    d = Path(dir_ or cfg["watch_dir"]).expanduser()
    d.mkdir(parents=True, exist_ok=True)
    print(t("überwache", "watching") + f" {d}", flush=True)
    seen = {}
    stamp = _code_stamp()
    while True:
        cfg = config.load()           # je Durchgang frisch: Modellwechsel, Schwellen, Formate gelten ohne Neustart
        now = _code_stamp()
        if now != stamp and time.time() - now[1] >= settle:   # geändert und seit settle s ruhig (kein halbes Update)
            print(f"{time.strftime('%H:%M:%S')} " + t("Code geändert, starte neu", "code changed, restarting"), flush=True)
            os.execv(sys.argv[0], sys.argv)
        for f in _pending(d):
            try:
                st = f.stat()
            except OSError:                              # während eines vorigen Auftrags verschwunden
                continue
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
                try:
                    f.with_name(f.stem + ".error.txt").write_text(traceback.format_exc())
                except OSError:                          # Ordner inzwischen weg
                    pass
                print("   " + t("FEHLER, siehe", "ERROR, see") + f" {f.stem}.error.txt", flush=True)
            seen.pop(f, None)
        time.sleep(interval)
