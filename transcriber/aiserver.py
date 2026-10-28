"""Lokalen KI-Server bei Bedarf starten und nach Leerlauf wieder beenden (Einstellungen › KI › Startbefehl).

Ist der eingestellte lokale Server nicht erreichbar und ein Startbefehl hinterlegt (z. B. `~/bin/mtplx-serve`,
`ollama serve`), startet der Kern einen Aufpasser (`transcriber ai-server --supervise`, eigene Sitzung, überlebt
App/CLI) und wartet, bis der Server antwortet. Der Aufpasser startet den Befehl als Kindprozess und beendet ihn, wenn
`idle_stop_min` Minuten lang niemand ihn benutzt hat (0 = nie) – oder auf `ai-server --stop` (App beim Beenden mit
--if-idle). Einen Server, den man selbst gestartet hat, fasst Transcriber nie an: es gibt dann keinen Aufpasser.

Benutzung: Jede Anfrage (summarize.run, Verbindungstest) legt für ihre Dauer DATA/ai-server.busy/<pid> an und setzt
danach DATA/ai-server.used. Solange eine Markierung eines lebenden Prozesses liegt, wird nicht beendet.

Startbefehle, die sofort zurückkehren und den Server woanders laufen lassen (`lms server start`), gehen auch: dann
beendet nur ein Stoppbefehl (`stop_command`, z. B. `lms server stop`) den Server; ohne ihn bleibt er an."""
import fcntl
import json
import os
import signal
import subprocess
import sys
import time
import urllib.error
import urllib.request
from contextlib import contextmanager

from . import config
from .i18n import t

STATE = config.DATA / "ai-server.json"
LOG = config.DATA / "ai-server.log"
BUSY = config.DATA / "ai-server.busy"
USED = config.DATA / "ai-server.used"
LOCK = config.DATA / "ai-server.lock"


def _settings():
    from . import summarize
    return summarize.settings()


def up(base_url, timeout=2):
    """Antwortet der Server? Auch ein HTTP-Fehler (401, 404) heißt: er läuft."""
    try:
        urllib.request.urlopen(base_url.rstrip("/") + "/models", timeout=timeout).close()
        return True
    except urllib.error.HTTPError:
        return True
    except (urllib.error.URLError, TimeoutError, ConnectionError, OSError):
        return False


def _alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except (OSError, TypeError):
        return False


def _is_supervisor(pid):
    """Ist pid wirklich ein Aufpasser? Nach einem Absturz bleibt ai-server.json liegen, die PID bekommt später ein
    fremder Prozess – den nie als „läuft“ werten oder gar beenden."""
    try:
        cmd = subprocess.run(["/bin/ps", "-p", str(int(pid)), "-o", "command="], capture_output=True, text=True,
                             timeout=10).stdout
    except (OSError, ValueError, TypeError, subprocess.TimeoutExpired):
        return False
    return "ai-server" in cmd and "--supervise" in cmd


def state():
    """Angaben des laufenden Aufpassers oder None (keiner da / abgestürzt)."""
    try:
        st = json.loads(STATE.read_text())
    except (OSError, ValueError):
        return None
    return st if _alive(st.get("pid")) and _is_supervisor(st.get("pid")) else None


def busy():
    """PIDs, die den Server gerade benutzen (Markierungen toter Prozesse werden entfernt)."""
    out = []
    for f in BUSY.glob("*") if BUSY.exists() else []:
        if f.name.isdigit() and _alive(int(f.name)):
            out.append(int(f.name))
        else:
            f.unlink(missing_ok=True)
    return out


def _env():
    """Ein Finder-Start der App hat nur den System-PATH – Homebrew und ~/bin dazu, damit `ollama`, `mtplx` usw. gehen."""
    env = dict(os.environ)
    home = os.path.expanduser("~")
    extra = ["/opt/homebrew/bin", "/usr/local/bin", f"{home}/.local/bin", f"{home}/bin"]
    env["PATH"] = ":".join(extra + [p for p in env.get("PATH", "").split(":") if p and p not in extra])
    return env


def _log_tail(n=5):
    try:
        return " | ".join(LOG.read_text(errors="replace").strip().splitlines()[-n:])
    except OSError:
        return ""


def ensure(s=None, progress=None):
    """Server erreichbar machen. Liefert True, wenn er dafür gestartet werden musste."""
    from . import summarize
    s = s or _settings()
    cmd = (s.get("start_command") or "").strip()
    if not cmd or not summarize.is_local(s["base_url"]) or up(s["base_url"]):
        return False
    config.DATA.mkdir(parents=True, exist_ok=True)
    with open(LOCK, "w") as lk:                          # zwei Zusammenfassungen gleichzeitig starten nur einen Server
        fcntl.flock(lk, fcntl.LOCK_EX)
        if not state() and not up(s["base_url"]):
            with open(LOG, "w") as log:
                subprocess.Popen([sys.executable, "-m", "transcriber.cli", "ai-server", "--supervise"], stdin=subprocess.DEVNULL,
                                 stdout=log, stderr=subprocess.STDOUT, start_new_session=True, env=_env())
            time.sleep(0.5)
    if progress:
        progress(t("Sprachmodell wird gestartet", "starting the language model"))
    t0 = time.time()
    while time.time() - t0 < float(s.get("start_timeout_s") or 180):
        if up(s["base_url"]):
            return True
        if not state() and time.time() - t0 > 5:      # Aufpasser schon wieder weg: Befehl gescheitert
            raise RuntimeError(t(f"Startbefehl beendet, Server antwortet nicht ({cmd}): {_log_tail()}",
                                 f"start command ended, server not answering ({cmd}): {_log_tail()}"))
        time.sleep(1)
    raise RuntimeError(t(f"Server nach dem Start nicht erreichbar ({s['base_url']}): {_log_tail()}",
                         f"server not reachable after start ({s['base_url']}): {_log_tail()}"))


@contextmanager
def using(s=None, progress=None):
    """Um eine Anfrage legen: startet bei Bedarf und hält den Server währenddessen am Leben."""
    BUSY.mkdir(parents=True, exist_ok=True)
    mark = BUSY / str(os.getpid())
    mark.touch()
    try:
        ensure(s, progress)
        yield
    finally:
        mark.unlink(missing_ok=True)
        USED.touch()


def _stop_server(child, s):
    stop_cmd = (s.get("stop_command") or "").strip()
    if stop_cmd:
        try:
            subprocess.run(["/bin/sh", "-c", stop_cmd], env=_env(), timeout=60)
        except (OSError, subprocess.TimeoutExpired) as e:
            print(f"stop_command: {e}", flush=True)
    if child.poll() is None:
        try:
            os.killpg(child.pid, signal.SIGTERM)
            child.wait(20)
        except subprocess.TimeoutExpired:
            os.killpg(child.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass


def supervise():
    """Aufpasser: Startbefehl ausführen, bei Leerlauf oder SIGTERM beenden."""
    s = _settings()
    cmd = s["start_command"]
    stop = []
    signal.signal(signal.SIGTERM, lambda *_: stop.append("SIGTERM"))
    started = time.time()
    child = subprocess.Popen(["/bin/sh", "-c", cmd], stdin=subprocess.DEVNULL, start_new_session=True, env=_env())
    STATE.write_text(json.dumps({"pid": os.getpid(), "child": child.pid, "command": cmd, "base_url": s["base_url"],
                                 "started": time.strftime("%Y-%m-%d %H:%M:%S")}))
    print(f"[ai-server] {time.strftime('%H:%M:%S')} gestartet: {cmd} (pid {child.pid})", flush=True)
    seen_up = False
    reason = ""
    try:
        while not stop:
            for _ in range(5):                           # SIGTERM sofort beachten, sonst alle 5 s prüfen
                if not stop:
                    time.sleep(1)
            if stop:
                break
            s = _settings()                              # geänderte Wartezeit in der App gilt sofort
            is_up = up(s["base_url"])
            seen_up = seen_up or is_up
            if child.poll() is not None and not is_up:
                reason = f"Server beendet (Exit {child.returncode})"
                break
            if not seen_up and time.time() - started > float(s.get("start_timeout_s") or 180) + 30:
                reason = "Server antwortet nicht"
                break
            idle = float(s.get("idle_stop_min") or 0)
            try:
                last = max(started, USED.stat().st_mtime)
            except OSError:
                last = started
            if idle > 0 and not busy() and time.time() - last > idle * 60:
                reason = f"{idle:g} min nicht benutzt"
                break
        reason = reason or (stop[0] if stop else "")
        print(f"[ai-server] {time.strftime('%H:%M:%S')} beende: {reason}", flush=True)
        _stop_server(child, s)
    finally:
        STATE.unlink(missing_ok=True)


def stop(if_idle=False):
    """Von Transcriber gestarteten Server beenden. Liefert, was passiert ist (für CLI/App)."""
    st = state()
    if not st:
        return "none"
    if if_idle and busy():
        return "busy"
    os.kill(st["pid"], signal.SIGTERM)
    return "stopping"


def status():
    s = _settings()
    st = state()
    try:
        used = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(USED.stat().st_mtime))
    except OSError:
        used = None
    return {"base_url": s["base_url"], "up": up(s["base_url"]), "start_command": s.get("start_command") or "",
            "idle_stop_min": s.get("idle_stop_min"), "started_by_transcriber": bool(st), "supervisor": st,
            "busy": busy(), "last_used": used}
