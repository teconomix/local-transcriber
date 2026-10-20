"""Diktat: dauerhaft laufender Dienst, der kurze Aufnahmen sofort in Text verwandelt.

Die App startet `transcriber dictate-server`; das Modell bleibt geladen, ein Diktat von 10 s braucht dann
Sekundenbruchteile statt mehrerer Sekunden Python-/MLX-/Modellstart. Unabhängig von der Auftrags-Warteschlange
(`run.lock`): ein Diktat wartet nie hinter einer Meeting-Transkription. Audio wird nicht gespeichert.

Protokoll am Unix-Socket DATA/dictate.sock, eine Anfrage je Verbindung:
    → eine JSON-Zeile {"language": "de", "samples": N}, danach N × float32 (little endian, 16 kHz, mono)
    ← eine JSON-Zeile {"text": "...", "ms": 312, "audio_s": 4.1} oder {"error": "..."}

Kein Live-Text: Parakeet-Streaming (2026-10-10 ausprobiert) flackerte, driftete ins Englische und half im Alltag nicht.
"""
import json
import os
import socket
import socketserver
import sys
import threading
import time

import numpy as np

from . import asr, config, glossary
from .i18n import t


SOCK = config.DATA / "dictate.sock"
RATE = 16000
# Whisper erfindet bei Stille gern Abspann-Floskeln. Nur verwerfen, wenn das *ganze* Diktat so lautet.
PHANTOM = ("untertitel", "vielen dank fürs zuschauen", "vielen dank für ihre aufmerksamkeit", "danke fürs zuschauen",
           "thank you for watching", "thanks for watching")


def trim_silence(a, frame=0.02, rel_db=-35.0, pad=0.25):
    """Schneidet Stille vorn und hinten ab (Schwelle relativ zum lautesten 20-ms-Fenster). None = nur Stille."""
    n = int(RATE * frame)
    if len(a) < n:
        return None
    k = len(a) // n
    rms = np.sqrt(np.mean(a[:k * n].reshape(k, n) ** 2, axis=1) + 1e-12)
    db = 20 * np.log10(rms)
    if db.max() < -50:                       # absolut zu leise: Mikrofon stumm oder nichts gesagt
        return None
    loud = np.where(db > db.max() + rel_db)[0]
    p = int(pad / frame)
    s, e = max(0, loud[0] - p), min(k, loud[-1] + 1 + p)
    if (e - s) * frame < 0.3:
        return None
    return a[s * n:e * n]


def transcribe(samples, language="de"):
    t0 = time.monotonic()
    a = trim_silence(np.asarray(samples, dtype=np.float32))
    text = ""
    if a is not None:
        import mlx_whisper
        r = mlx_whisper.transcribe(a, path_or_hf_repo=asr.REPO, language=language, verbose=None,
                                   condition_on_previous_text=False)
        text = " ".join(s["text"].strip() for s in r["segments"] if s["text"].strip()).replace("\ufffd", "")  # halbe Zeichen
        if text.lower().strip(" .!").startswith(PHANTOM) and len(text) < 60:
            text = ""
        text = _glossary(text)
    return {"text": text, "ms": round((time.monotonic() - t0) * 1000), "audio_s": round(len(samples) / RATE, 2)}


def _glossary(text):
    from pathlib import Path
    _, rules = glossary.load(Path(config.load()["vocab_file"]).expanduser())
    return glossary.apply_text(text, rules)


def _read_exact(f, n):
    buf = bytearray()
    while len(buf) < n:
        chunk = f.read(n - len(buf))
        if not chunk:
            raise EOFError(t("Verbindung vor Ende der Audiodaten geschlossen", "connection closed before end of audio data"))
        buf += chunk
    return bytes(buf)


class Handler(socketserver.StreamRequestHandler):
    def handle(self):
        try:
            head = json.loads(self.rfile.readline())
            n = int(head["samples"])
            samples = np.frombuffer(_read_exact(self.rfile, n * 4), dtype="<f4")
            res = transcribe(samples, head.get("language", "de"))
            print(t("diktat", "dictation") + f" {res['audio_s']:.1f} s → {res['ms']} ms, {len(res['text'])} " + t("Zeichen", "characters"), file=sys.stderr, flush=True)
        except Exception as e:  # Fehler an die App melden statt den Dienst zu beenden
            res = {"error": f"{type(e).__name__}: {e}"}
            print(t("diktat FEHLER", "dictation ERROR") + f" {res['error']}", file=sys.stderr, flush=True)
        self.wfile.write((json.dumps(res, ensure_ascii=False) + "\n").encode())


def _alive():
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
            s.connect(str(SOCK))
        return True
    except OSError:
        return False


def serve():
    config.offline_env()
    if SOCK.exists():
        if _alive():
            print(t("Diktat-Dienst läuft bereits", "Dictation service already running"), file=sys.stderr)
            return 0
        SOCK.unlink()
    # Modell laden und einmal durchrechnen, damit das erste echte Diktat nicht den Kaltstart bezahlt.
    t0 = time.monotonic()
    import mlx_whisper
    mlx_whisper.transcribe(np.zeros(RATE, dtype=np.float32), path_or_hf_repo=asr.REPO, language="de", verbose=None)
    print(t("Diktat-Dienst bereit", "Dictation service ready") + f" ({time.monotonic() - t0:.1f} s), {SOCK}", file=sys.stderr, flush=True)
    old = os.umask(0o077)                     # Socket nur für diesen Benutzer
    try:
        srv = socketserver.UnixStreamServer(str(SOCK), Handler)
    finally:
        os.umask(old)
    # Endet mit der App: wurde sie beendet (auch per kill, Absturz, Installer-Update), blieb der Dienst verwaist
    # (Eltern-PID 1) mit altem Code zurück, und die neue App nahm ihn weiter (2026-10-20: knapp 6 Tage alt).
    parent = os.getppid()
    def watch():
        while os.getppid() == parent:
            time.sleep(5)
        print(t("App beendet – Diktat-Dienst endet", "App quit – dictation service stops"), file=sys.stderr, flush=True)
        srv.shutdown()
    threading.Thread(target=watch, daemon=True).start()
    try:
        srv.serve_forever()                   # bewusst einzeln nacheinander: ein Modell, eine GPU-Warteschlange
    finally:
        SOCK.unlink(missing_ok=True)


def request(samples, language="de", timeout=120):
    """Client (CLI-Test): schickt Samples am Stück an den laufenden Dienst."""
    data = np.asarray(samples, dtype="<f4").tobytes()
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
        s.settimeout(timeout)
        s.connect(str(SOCK))
        s.sendall((json.dumps({"language": language, "samples": len(data) // 4}) + "\n").encode() + data)
        f = s.makefile("rb")
        return json.loads(f.readline())

