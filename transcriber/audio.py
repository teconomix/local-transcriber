"""Audio vorbereiten: alle Tonspuren mischen, Lautheit angleichen, 16 kHz mono."""
import json
import shutil
import subprocess
from pathlib import Path

from . import config
from .i18n import t


def tool(name):
    """ffmpeg/ffprobe: vom Installer nach DATA/bin gelegt (statischer Build), sonst aus dem PATH (z. B. Homebrew)."""
    local = config.DATA / "bin" / name
    return str(local) if local.exists() else (shutil.which(name) or name)


def probe(path):
    out = subprocess.run([tool("ffprobe"), "-v", "error", "-show_entries", "stream=index,codec_type,codec_name:format=duration",
                          "-of", "json", str(path)], capture_output=True, text=True, check=True).stdout
    d = json.loads(out)
    tracks = [s["index"] for s in d.get("streams", []) if s.get("codec_type") == "audio" and s.get("codec_name") != "unknown"]
    return tracks, float(d.get("format", {}).get("duration", 0))


def prepare(src, dst):
    """Schreibt dst (WAV 16 kHz mono). Mehrere Tonspuren (z. B. Mikrofon + Systemton) werden ohne
    Normalisierung gemischt und danach per loudnorm angeglichen – die Spuren haben sehr verschiedene Pegel."""
    tracks, dur = probe(src)
    if not tracks:
        raise ValueError(t("keine Tonspur in", "no audio track in") + f" {src}")
    if len(tracks) > 1:
        ins = "".join(f"[0:a:{i}]" for i in range(len(tracks)))
        af = ["-filter_complex", f"{ins}amix=inputs={len(tracks)}:normalize=0,loudnorm=I=-18"]
    else:
        af = ["-af", "loudnorm=I=-18"]
    Path(dst).parent.mkdir(parents=True, exist_ok=True)
    subprocess.run([tool("ffmpeg"), "-nostdin", "-v", "error", "-y", "-i", str(src), *af, "-ac", "1", "-ar", "16000", str(dst)],
                   check=True)
    return {"tracks": len(tracks), "duration": dur}


def prepare_tracks(src, dst_dir, n):
    """Jede Tonspur einzeln als WAV 16 kHz mono, Pegel unverändert: der Pegelvergleich je Wort braucht die echten
    Verhältnisse (loudnorm je Spur hob auf einer Mikrofonspur mit wenig eigener Sprache das Echo an – Test 2026-10-10,
    c3 mit Echo: WER 16,9 → 20,8 %). Liefert die Pfade in Spurreihenfolge."""
    Path(dst_dir).mkdir(parents=True, exist_ok=True)
    out = []
    for i in range(n):
        dst = Path(dst_dir) / f"track{i + 1}.wav"
        subprocess.run([tool("ffmpeg"), "-nostdin", "-v", "error", "-y", "-i", str(src), "-map", f"0:a:{i}",
                        "-ac", "1", "-ar", "16000", str(dst)], check=True)
        out.append(dst)
    return out


def track_relation(wavs, win_s=5.0, max_lag_ms=300, max_windows=80, rate=16000):
    """Sind zwei Spuren unabhängige Quellen (Mikrofon + Systemton eines Calls) oder Kopien desselben Raumklangs?

    Gemessen 2026-10-10 an Handy-Aufnahmen mit zwei Mikrofonen: Spur 1 war eine um 13 dB leisere, 10 ms
    frühere Kopie von Spur 2 – für alle Sprecher gleich, Korrelation 0,7. Bei einem Call ist die Mikrofonspur dagegen
    nur dort mit der Systemspur korreliert, wo die anderen sprechen (Echo); wo man selbst spricht, nicht.
    Kriterium: Anteil der aktiven 5-s-Fenster mit Korrelation ≥ 0,3. Liefert dict mit share_correlated, lag_ms, windows."""
    import numpy as np
    import soundfile as sf
    a, b = (sf.read(str(w), dtype="float32")[0] for w in wavs)
    n = min(len(a), len(b)); a, b = a[:n], b[:n]
    w = int(win_s * rate); L = int(max_lag_ms * rate / 1000)
    starts = list(range(0, n - w, w))
    def rms_db(x):
        return 10 * np.log10(np.mean(x ** 2) + 1e-12)
    active = [s for s in starts if max(rms_db(a[s:s + w]), rms_db(b[s:s + w])) > -45]
    if len(active) > max_windows:
        active = [active[int(i * len(active) / max_windows)] for i in range(max_windows)]
    corrs, lags = [], []
    m = 1 << int(np.ceil(np.log2(2 * w)))
    for s in active:
        x, y = a[s:s + w], b[s:s + w]
        den = np.sqrt(np.sum(x ** 2) * np.sum(y ** 2))
        if den < 1e-9:
            continue
        cc = np.fft.irfft(np.fft.rfft(x, m) * np.conj(np.fft.rfft(y, m)), m)
        c = np.concatenate([cc[-L:], cc[:L + 1]]) / den
        k = int(np.argmax(np.abs(c)))
        corrs.append(float(abs(c[k]))); lags.append((k - L) * 1000 / rate)
    if not corrs:
        return {"share_correlated": 0.0, "lag_ms": None, "windows": 0}
    hi = [i for i, c in enumerate(corrs) if c >= 0.3]
    return {"share_correlated": round(len(hi) / len(corrs), 2),
            "lag_ms": round(float(np.median([lags[i] for i in hi])), 1) if hi else None,
            "median_corr": round(float(np.median(corrs)), 2), "windows": len(corrs)}
