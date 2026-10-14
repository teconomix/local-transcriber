"""Ein Auftrag: Audio vorbereiten → Spracherkennung → Sprechertrennung → Stimmenabgleich → Ausgabe neben der Quelle."""
import contextlib
import fcntl
import hashlib
import json
import os
import sys
import threading
import time
from pathlib import Path

from . import asr, audio, config, glossary, render, speakers
from .i18n import t as tr

# Erfahrungswerte (Vielfaches der Echtzeit auf MacLion) für die Fortschrittsanzeige
RTFX = {"asr": 50, "diarize": 28}
STAGES = [("prepare", 0.03), ("asr", 0.55), ("diarize", 0.38), ("finish", 0.04)]


def job_id(path):
    h = hashlib.sha1()
    with open(path, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()[:12]


def _asr(wav, language, terms):
    """Spracherkennung mit Zwischenspeicher neben der WAV: Eine Neuauswertung (andere Sprecherzahl, „Neu auswerten“
    in der App) rechnet dann nur die Sprechertrennung neu. Gültig für dieselbe Aufnahme (Ordner = Inhalts-Hash),
    Sprache, Modell und Prompt; die Glossar-Ersetzungen laufen danach immer frisch."""
    f = Path(wav).with_name(f"asr-{language}.json")
    key = {"model": asr.MODEL, "terms": terms}
    with contextlib.suppress(OSError, ValueError, KeyError):
        c = json.loads(f.read_text())
        if c["key"] == key:
            return c["result"]
    r = asr.transcribe(wav, terms=terms, language=language)
    with contextlib.suppress(OSError):
        tmp = f.with_suffix(".tmp")
        tmp.write_text(json.dumps({"key": key, "result": r}, ensure_ascii=False))
        tmp.replace(f)
    return r


class Progress:
    """Meldet (stage, Anteil 0..1, Text) an den Aufrufer und schreibt DATA/jobs/<lauf>.json, damit die App alle
    laufenden Aufträge sieht (auch die von Wächter, CLI und MCP). Innerhalb einer Stufe wird anhand der erwarteten
    Dauer geschätzt."""

    def __init__(self, cb, src):
        self.cb, self.base, self.span, self.t0, self.exp, self.stage, self.msg = cb, 0.0, 0.0, 0.0, None, "", ""
        self.status = {"source": str(src), "pid": os.getpid(), "started": time.time(), "state": "running",
                       "stage": "", "progress": 0.0, "message": "", "result": None}
        config.JOBS.mkdir(parents=True, exist_ok=True)
        for old in config.JOBS.glob("*.json"):  # Statusdateien nach 2 Tagen aufräumen
            if time.time() - old.stat().st_mtime > 2 * 86400:
                old.unlink(missing_ok=True)
        self.path = config.JOBS / f"{int(time.time() * 1000)}-{os.getpid()}.json"
        self._stop = threading.Event()
        threading.Thread(target=self._tick, daemon=True).start()

    def start(self, stage, expected_s=None, msg=""):
        offs = 0.0
        for s, w in STAGES:
            if s == stage:
                self.base, self.span = offs, w
                break
            offs += w
        self.stage, self.t0, self.exp, self.msg = stage, time.time(), expected_s, msg or stage
        self._emit(self.base, self.msg)

    def _emit(self, frac, msg):
        frac = round(min(frac, 1.0), 3)
        self.status.update(stage=self.stage, progress=frac, message=msg, updated=time.time())
        tmp = self.path.with_suffix(".tmp")
        tmp.write_text(json.dumps(self.status, ensure_ascii=False)); tmp.replace(self.path)
        if self.cb:
            self.cb(self.stage, frac, msg)

    def _tick(self):
        while not self._stop.wait(1.0):
            if self.exp:
                f = min((time.time() - self.t0) / self.exp, 0.95)
                self._emit(self.base + self.span * f, self.msg)

    def done(self, paths):
        self._stop.set()
        self.status["result"] = {k: str(v) for k, v in paths.items()}
        self.status["state"] = "done"; self.stage = "done"; self._emit(1.0, tr("fertig", "done"))

    def failed(self, err):
        self._stop.set()
        self.status["state"] = "failed"; self.status["error"] = err; self._emit(self.status["progress"], tr("fehlgeschlagen", "failed"))


@contextlib.contextmanager
def exclusive(P):
    """Nur eine Transkription gleichzeitig auf dem Rechner (Speicher, GPU). Weitere warten hier."""
    config.DATA.mkdir(parents=True, exist_ok=True)
    with open(config.DATA / "run.lock", "w") as f:
        try:
            fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            P.start("prepare", msg=tr("wartet auf laufende Transkription", "waiting for running transcription"))
            fcntl.flock(f, fcntl.LOCK_EX)
        yield


def _run_tracks(tracks, wav, language, num_speakers, cfg, terms, rules, P, t, dur):
    """Zwei unabhängige Spuren (App: Spur 1 = Mikrofon, Spur 2 = Systemton/Call).

    Text kommt aus der gewohnten Mischung (audio.prepare): Whisper braucht den Gesprächszusammenhang –
    je Spur allein sieht es nur eine Gesprächshälfte (Test 2026-10-10, c2_dialog: WER 14 % statt 9,5 %).
    Wer spricht, kommt aus den Spuren: je Wort die lautere Spur, darin die Sprechertrennung dieser Spur (Labels
    T1:/T2:). Echo der Lautsprecher im Mikrofon ist ~13 dB leiser als die Systemspur und verliert so von selbst;
    Cluster ohne Wörter (z. B. reines Echo) fallen weg.
    Ausnahme gleichzeitiges Sprechen auf beiden Spuren: In der Mischung schreibt Whisper dann nur eine Stimme mit (Test
    2026-10-10: Video und eigene Sprache 10 s gleichzeitig → Video fehlte). Dort kommt der Text je Spur (_overlaps)."""
    import numpy as np
    import soundfile as sf
    from . import diarize
    x = [sf.read(str(w), dtype="float32")[0] for w in tracks]

    P.start("asr", dur / RTFX["asr"], tr("Spracherkennung", "Speech recognition"))
    t0 = time.time(); r = _asr(wav, language, terms if cfg["glossary_prompt"] else None)
    t["asr"] = time.time() - t0
    replaced = glossary.apply(r["words"], rules)
    mixed = r["words"]

    per = []
    for i, w in enumerate(tracks, 1):
        P.start("diarize", dur / RTFX["diarize"], tr("Sprechertrennung Spur", "Speaker separation track") + f" {i}/2")
        t0 = time.time()
        # Je Spur kann auch nur eine Person sprechen (Mikrofon: man selbst); Sprecherzahl-Vorgabe gilt für den Call.
        others = cfg.get("_others") or []         # Kalender: Call-Spur höchstens die anderen Teilnehmer + 1
        mx = cfg["max_speakers"] if i == 1 or not others else min(cfg["max_speakers"], len(others) + 1)
        segs, clusters = diarize.diarize(w, 1, mx, num_speakers if i == 2 else None)
        t[f"diarize{i}"] = time.time() - t0
        for sg in segs:
            sg["speaker"] = f"T{i}:" + sg["speaker"]
        for c in clusters:
            c["label"] = f"T{i}:" + c["label"]; c["track"] = i
        per.append((segs, _merge_similar(clusters, segs, [], cfg.get("merge_sim", 0.6))))

    echo = _echo_clusters(x[0], x[1], per[0][0], per[0][1])
    t["echo_clusters"] = len(echo)
    found = _overlaps(per[0][0], per[1][0], echo)
    regions = [r for r in found if _both_speaking(x[0], x[1], *r)]
    t["overlap_candidates"] = len(found)
    extra, spans = {1: [], 2: []}, []      # spans: tatsächlich je Spur transkribierte Überlappungen
    if regions:
        P.start("asr", sum(e - s for s, e in regions) * 2 / RTFX["asr"], tr("Gleichzeitiges Sprechen", "Overlapping speech"))
        t0 = time.time()
        for s, e in regions:
            ws = [_transcribe_span(x[k - 1], s, e, tracks[k - 1].parent / f"overlap{k}.wav", language) for k in (1, 2)]
            # Whisper unsicher (erfundene Wörter aus Restecho/Rauschen, p meist < 0,5): Bereich bleibt bei der Mischung
            if not all(w and sum(v.get("p") or 0 for v in w) / len(w) >= 0.5 for w in ws):
                continue
            spans.append((s, e))
            for k in (1, 2):
                replaced += glossary.apply(ws[k - 1], rules)
                extra[k] += ws[k - 1]
        inside = lambda w: any(s <= (w["start"] + w["end"]) / 2 < e for s, e in spans)
        mixed = [w for w in mixed if not inside(w)]
        for k in (1, 2):                                   # Ränder: Wort schon außerhalb des Bereichs in der Mischung
            extra[k] = _new_words(extra[k], mixed)
        t["overlap_s"], t["asr_overlap"] = round(sum(e - s for s, e in spans), 1), round(time.time() - t0, 1)

    # Lücken: Spur spricht laut Sprechertrennung, die Mischung hat dort > 2 s kein Wort (Whisper übersprang z. B. den
    # Anfang eines Videos direkt nach eigener Sprache, Test 2026-10-10) → diese Spur allein nachtranskribieren.
    t0, filled = time.time(), 0.0
    have = sorted(mixed + extra[1] + extra[2], key=lambda w: w["start"])
    for k in (1, 2):
        segs_k = [s for s in per[k - 1][0] if s["speaker"] not in (echo if k == 1 else ())]
        for s, e in _holes(have, segs_k, dur):
            if k == 1 and not _own_voice(x[0], x[1], s, e):
                continue
            ws = _new_words(_transcribe_span(x[k - 1], s, e, tracks[k - 1].parent / f"gap{k}.wav", language), have)
            # ≥ 3 Wörter: in Atempausen erfindet Whisper gern ein einzelnes Wort, auch mit hoher Sicherheit
            # (c1_monolog: „können.“ p 0,8); echte verschluckte Passagen sind länger
            if len(ws) >= 3 and sum(v.get("p") or 0 for v in ws) / len(ws) >= 0.5:
                replaced += glossary.apply(ws, rules)
                extra[k] += ws; filled += e - s
    if filled:
        t["gap_filled_s"], t["asr_gaps"] = round(filled, 1), round(time.time() - t0, 1)

    def level(a, w):
        i, j = int(max(w["start"] - 0.05, 0) * 16000), int((w["end"] + 0.05) * 16000)
        return float(np.mean(a[i:j] ** 2)) if j > i else 0.0
    by = {1: list(extra[1]), 2: list(extra[2])}
    for w in mixed:
        by[1 if level(x[0], w) >= level(x[1], w) else 2].append(w)
    for k in (1, 2):
        by[k].sort(key=lambda w: w["start"])
    words = []
    for i in (1, 2):
        words += assign_words(by[i], per[i - 1][0])
    mic = [w for w in words if (w["speaker"] or "").startswith("T1:")]
    _absorb_minor(per[0][1], mic, cfg, echo)
    # Kein Segment dieser Spur in der Nähe (z. B. Whisper-Wort am Rand einer Pause): Segmente der anderen Spur.
    loose = [w for w in words if w["speaker"] is None]
    if loose:
        assign_words(loose, sorted(per[0][0] + per[1][0], key=lambda s: s["start"]))
    words.sort(key=lambda w: w["start"])
    used = {w["speaker"] for w in words}
    clusters = [c for _, cl in per for c in cl if c["label"] in used]
    t["words_track1"], t["words_track2"] = len(by[1]), len(by[2])
    return words, sorted(per[0][0] + per[1][0], key=lambda s: s["start"]), clusters, replaced, spans


def _overlaps(segs1, segs2, echo=(), min_s=1.0, join_s=1.0, pad=0.3):
    """Zeitbereiche, in denen laut Sprechertrennung auf beiden Spuren gleichzeitig gesprochen wird (Echo-Cluster der
    Mikrofonspur zählen nicht – das ist dieselbe Stimme). Kurze Einwürfe unter min_s bleiben in der Mischung."""
    def merged(segs):
        out = []
        for sg in sorted(segs, key=lambda s: s["start"]):
            if out and sg["start"] - out[-1][1] < join_s:
                out[-1][1] = max(out[-1][1], sg["end"])
            else:
                out.append([sg["start"], sg["end"]])
        return out
    a = merged([s for s in segs1 if s["speaker"] not in echo])
    b = merged(segs2)
    hits = [[max(s1, s2), min(e1, e2)] for s1, e1 in a for s2, e2 in b if min(e1, e2) - max(s1, s2) > 0]
    regions = []
    for s, e in sorted(hits):
        if regions and s - regions[-1][1] < join_s:
            regions[-1][1] = max(regions[-1][1], e)
        else:
            regions.append([s, e])
    return [(max(s - pad, 0.0), e + pad) for s, e in regions if e - s >= min_s]


def _both_speaking(mic, call, s, e, rate=16000, max_db=15.0, floor_db=-50.0, max_lag=0.15, thr=0.15):
    """Sprechen in [s, e) wirklich beide? Nein, wenn eine Spur viel leiser ist (Restecho, Rauschen: im Test 2026-10-10
    hörte das Mikrofon ein Video mit −44 dB gegenüber −26 dB mit – Whisper erfand daraus deutsche Sätze) oder wenn die
    Mikrofonspur mit der Call-Spur korreliert (Echo über Lautsprecher, dieselbe Stimme). Gemessen 2026-10-10: Restecho,
    während sich die Echounterdrückung einstellt, 0,25–0,29; echtes gleichzeitiges Sprechen 0,03–0,06."""
    import numpy as np
    i, j = int(s * rate), int(e * rate)
    a, b = mic[i:j], call[i:j]
    if len(a) < rate // 2 or len(b) < rate // 2:
        return False
    da, db = (10 * np.log10(np.mean(v ** 2) + 1e-12) for v in (a, b))
    if min(da, db) < floor_db or abs(da - db) > max_db:
        return False
    return _corr(mic, call, i, j, int(max_lag * rate)) < thr


def _corr(mic, call, i, j, L):
    """Höchste normierte Korrelation von mic[i:j] mit der Call-Spur bei Versatz bis ±L Samples. Am Rand der Aufnahme
    mit Stille aufgefüllt – sonst blieb dort nur ein Versatz übrig und verzögertes Echo fiel durch."""
    import numpy as np
    a = mic[i:j]
    lo, hi = i - L, j + L
    bb = np.pad(call[max(lo, 0):min(hi, len(call))], (max(0, -lo), max(0, hi - len(call))))
    den = np.sqrt(np.sum(a ** 2)) * np.sqrt(np.max(np.convolve(bb ** 2, np.ones(len(a)), "valid")))
    return 0.0 if den < 1e-9 else float(np.max(np.abs(np.correlate(bb, a, "valid"))) / den)


def _new_words(ws, have, win=2.0):
    """Nachtranskribierte Wörter ohne Satzzeichen-Wörter („?“ für Lachen) und ohne solche, die innerhalb von win s
    schon dastehen – die Einzelspur setzt dasselbe Wort oft um bis zu 1 s anders an als die Mischung (Messung
    bench/tracks_test.py 2026-10-10: sonst c1 +6, c2 Echo +1 Wort)."""
    key = lambda w: "".join(c for c in w["w"].lower() if c.isalnum())
    return [w for w in ws if key(w) and not any(key(h) == key(w) and abs(h["start"] - w["start"]) <= win for h in have)]


def _holes(words, segs, dur, min_gap=2.0, min_speech=1.5):
    """Zeitbereiche ohne jedes Wort (> min_gap s), in denen diese Spur laut Sprechertrennung ≥ min_speech s spricht –
    beschnitten auf die Sprache der Spur."""
    edges = [0.0] + [v for w in words for v in (w["start"], w["end"])] + [dur]
    gaps = [(edges[i], edges[i + 1]) for i in range(0, len(edges) - 1, 2) if edges[i + 1] - edges[i] > min_gap]
    out = []
    for gs, ge in gaps:
        sp = [(max(s["start"], gs), min(s["end"], ge)) for s in segs if min(s["end"], ge) > max(s["start"], gs)]
        if sum(e - s for s, e in sp) >= min_speech:
            out.append((min(s for s, _ in sp), max(e for _, e in sp)))
    return out


def _own_voice(mic, call, s, e, rate=16000, max_lag=0.15, thr=0.15):
    """Mikrofonspur in [s, e) ist nicht bloß Echo der Call-Spur (Korrelation < thr, siehe _both_speaking)."""
    i, j = int(s * rate), int(e * rate)
    if j - i < rate // 2:
        return True
    return _corr(mic, call, i, j, int(max_lag * rate)) < thr


def _transcribe_span(x, s, e, tmp, language, rate=16000, ctx=0.5):
    """Ausschnitt einer Spur transkribieren; Wörter mit Zeiten der ganzen Aufnahme, nur die mit Mitte in [s, e)."""
    import soundfile as sf
    a = max(s - ctx, 0.0)
    sf.write(str(tmp), x[int(a * rate):int((e + ctx) * rate)], rate)
    ws = asr.transcribe(tmp, language=language)["words"]
    for w in ws:
        w["start"] = round(w["start"] + a, 3); w["end"] = round(w["end"] + a, 3)
    return [w for w in ws if s <= (w["start"] + w["end"]) / 2 < e]


def _echo_clusters(mic, call, segs, clusters, max_lag=0.15, rate=16000, thr=0.3):
    """Labels der Mikrofon-Cluster, die Echo der Lautsprecher sind: in ihren Segmenten mit der Call-Spur korreliert
    (Median ≥ thr über bis zu 12 Segmente ≥ 0,5 s, Versatz bis max_lag s). Eigene Sprache ist mit der Call-Spur nicht
    korreliert – auch wenn gleichzeitig jemand im Call spricht."""
    import numpy as np
    L = int(max_lag * rate)
    out = set()
    for c in clusters:
        ss = [s for s in segs if s["speaker"] == c["label"] and s["end"] - s["start"] >= 0.5]
        ss = sorted(ss, key=lambda s: s["start"] - s["end"])[:12]
        vals = []
        for sg in ss:
            i, j = int(sg["start"] * rate), int(sg["end"] * rate)
            a, b = mic[i:j], call[max(i - L, 0):j + L]
            if len(a) < rate // 2 or len(b) < len(a):
                continue
            den = np.sqrt(np.sum(a ** 2)) * np.sqrt(np.max(np.convolve(b ** 2, np.ones(len(a)), "valid")))
            if den < 1e-9:
                continue
            cc = np.correlate(b, a, "valid")
            vals.append(float(np.max(np.abs(cc)) / den))
        if vals and float(np.median(vals)) >= thr:
            out.add(c["label"])
    return out


def _absorb_minor(clusters, words, cfg, echo=(), share=0.25):
    """Mikrofonspur: Cluster mit wenig Wörtern (< share der Wörter der Spur) der Hauptstimme zuschlagen – außer sie
    passen sicher zu einer anderen bekannten Person (dann sitzt wirklich jemand mit im Raum). Gezählt werden Wörter,
    nicht Sprechzeit: ein Echo-Cluster hat viel Sprechzeit, aber kaum eigene Wörter (die gehen an die lautere
    Systemspur). Test 2026-10-10: die eigene Stimme zerfiel in „Sprecher D“ bzw. einen mit Echo vermischten Cluster,
    der einer anderen Person zugeordnet wurde."""
    from collections import Counter
    n = Counter(w["speaker"] for w in words)
    if len(n) < 2:
        return
    probe = [dict(c) for c in clusters]
    speakers.identify(speakers.connect(), probe, cfg)             # nur lesen: wer passt sicher zu wem?
    main = next((lab for lab, _ in n.most_common() if lab not in echo), n.most_common(1)[0][0])
    main_pid = next((p["person_id"] for p in probe if p["label"] == main), None)
    total = sum(n.values())
    for pr in probe:
        lab = pr["label"]
        own = pr["person_id"] is not None and pr["person_id"] != main_pid and (pr["score"] or 0) >= cfg["match_sure"]
        if lab == main or (lab not in echo and (own or n[lab] >= share * total)):
            continue                                   # Echo wird immer zugeschlagen, auch wenn es „sicher“ passt
        for w in words:
            if w["speaker"] == lab:
                w["speaker"] = main


def _merge_similar(clusters, segs, words, thr):
    """Cluster einer Spur mit ähnlicher Stimme (Kosinus ≥ thr) zu einem zusammenlegen. pyannote zerlegt eine einzelne
    Stimme auf der Mikrofonspur gern in mehrere Cluster (Test 2026-10-10: eine Person allein → 3 Cluster). Gemessen in der
    Stimmdatenbank: gleiche Person 0,68–0,98, verschiedene ≤ 0,45 → Schwelle 0,6 dazwischen."""
    import numpy as np
    cl = sorted(clusters, key=lambda c: -c["speech_s"])
    while True:
        best = None
        for i in range(len(cl)):
            for j in range(i + 1, len(cl)):
                sim = float(speakers._unit(cl[i]["embedding"]) @ speakers._unit(cl[j]["embedding"]))
                if sim >= thr and (best is None or sim > best[0]):
                    best = (sim, i, j)
        if best is None:
            return cl
        _, i, j = best
        a, b = cl[i], cl[j]
        wa, wb = a["speech_s"], b["speech_s"]
        a["embedding"] = (np.asarray(a["embedding"]) * wa + np.asarray(b["embedding"]) * wb) / max(wa + wb, 1e-9)
        a["speech_s"] = round(wa + wb, 1)
        for x in segs + words:
            if x.get("speaker") == b["label"]:
                x["speaker"] = a["label"]
        del cl[j]


def assign_words(words, segs):
    """Jedes Wort dem Sprecher zuordnen, dessen Segment die Wortmitte enthält (sonst nächstes Segment ≤ 1 s,
    sonst wie das vorige Wort). Danach kurze Einsprengsel (≤ 2 Wörter, < 1 s) zwischen gleichem Sprecher glätten."""
    j, prev = 0, None
    for w in words:
        m = (w["start"] + w["end"]) / 2
        while j < len(segs) and segs[j]["end"] < m:
            j += 1
        spk = None
        if j < len(segs) and segs[j]["start"] <= m <= segs[j]["end"]:
            spk = segs[j]["speaker"]
        else:
            near = [s for s in segs[max(j - 1, 0): j + 1] if min(abs(s["start"] - m), abs(s["end"] - m)) <= 1.0]
            if near:
                spk = min(near, key=lambda s: min(abs(s["start"] - m), abs(s["end"] - m)))["speaker"]
        w["speaker"] = spk or prev
        prev = w["speaker"]
    i = 0
    while i < len(words):
        k = i
        while k < len(words) and words[k]["speaker"] == words[i]["speaker"]:
            k += 1
        if 0 < i and k < len(words) and k - i <= 2 and words[i - 1]["speaker"] == words[k]["speaker"] \
                and words[k - 1]["end"] - words[i]["start"] < 1.0:
            for x in words[i:k]:
                x["speaker"] = words[i - 1]["speaker"]
        i = k
    return words


def turns(words):
    out = []
    for w in words:
        if out and out[-1]["speaker"] == w["speaker"] and w["start"] - out[-1]["end"] < 5:
            out[-1]["text"] += " " + w["w"]; out[-1]["end"] = w["end"]
        else:
            out.append({"speaker": w["speaker"], "start": w["start"], "end": w["end"], "text": w["w"]})
    return out


def display_names(clusters, words):
    """Anzeigenamen: sicher/bestätigt → Name, vermutlich → „Name (?)“, unbekannt → „Sprecher A/B/…“ in Reihenfolge des Auftretens."""
    order = list(dict.fromkeys(w["speaker"] for w in words if w["speaker"]))
    order += [c["label"] for c in clusters if c["label"] not in order]
    letters = {lab: chr(65 + i) for i, lab in enumerate(order)}
    for c in clusters:
        c["letter"] = letters.get(c["label"], "?")
        if c.get("name") and c["status"] in ("sicher", "bestätigt"):
            c["display"] = c["name"]
        elif c.get("name"):
            c["display"] = f"{c['name']} (?)"
        else:
            c["display"] = tr("Sprecher", "Speaker") + f" {c['letter']}"
    return clusters


def run(src, out_dir=None, formats=None, num_speakers=None, progress=None, cfg=None, language=None):
    cfg = cfg or config.load()
    config.offline_env()
    src = Path(src).expanduser().resolve()
    language = language or cfg["language"]
    formats = formats or cfg["formats"]
    terms, rules = glossary.load(Path(cfg["vocab_file"]).expanduser())
    moved = None
    if not num_speakers:                 # im Finder umbenannt/verschoben: Transkript nachziehen statt neu rechnen
        try:
            moved = adopt(src)
        except Exception as e:           # dann eben normal transkribieren
            print(tr("Nachziehen fehlgeschlagen: ", "moving transcript failed: ") + str(e), file=sys.stderr)
    if moved:
        Progress(progress, src).done(moved[1])
        return moved
    P = Progress(progress, src)
    t = {}
    lock = src.with_name(src.stem + ".lock")  # hält watch.py und parallele Aufrufe fern
    lock.write_text(str(os.getpid()))
    try:
        with exclusive(P):
            doc, paths = _run(src, language, out_dir, formats, num_speakers, cfg, terms, rules, P, t)
        P.done(paths)
        return doc, paths
    except BaseException as e:
        P.failed(f"{type(e).__name__}: {e}")
        raise
    finally:
        lock.unlink(missing_ok=True)


def _run(src, language, out_dir, formats, num_speakers, cfg, terms, rules, P, t):

    P.start("prepare", msg=tr("Audio vorbereiten", "Preparing audio"))
    event, others = load_event(src)
    if others:   # Kalender: höchstens die Eingeladenen (+1 für Ungeladene) – grenzt die Sprechertrennung ein
        cfg = dict(cfg, max_speakers=min(cfg["max_speakers"], len(others) + 2))
    jid = job_id(src)
    wav = config.CACHE / jid / "audio.wav"
    t0 = time.time()
    if wav.exists():                     # Neuauswertung: Ordner = Inhalts-Hash, die WAV wird nur fertig dort abgelegt
        n, d = audio.probe(src)
        info = {"tracks": len(n), "duration": d}
    else:
        info = audio.prepare(src, wav)
    t["prepare"] = time.time() - t0
    dur = info["duration"]
    mode, relation = "gemischt", None
    if info["tracks"] == 2 and cfg.get("track_mode", "auto") != "gemischt":
        tracks = [config.CACHE / jid / f"track{i}.wav" for i in (1, 2)]
        if not all(p.exists() for p in tracks):
            tracks = audio.prepare_tracks(src, config.CACHE / jid, 2)
        relation = audio.track_relation(tracks)
        # Kopien desselben Raumklangs (fast alle Fenster korreliert) bleiben gemischt; sonst Mikrofon + Call getrennt.
        if cfg.get("track_mode") == "getrennt" or relation["windows"] and relation["share_correlated"] < cfg.get("copy_share", 0.9):
            mode = "getrennt"
        t["prepare"] = time.time() - t0

    overlaps = []                        # Bereiche gleichzeitigen Sprechens (nur getrennte Spuren) – für die Ausgabe
    if mode == "getrennt":
        cfg = dict(cfg, _others=others)
        words, segs, clusters, replaced, overlaps = _run_tracks(tracks, wav, language, num_speakers, cfg, terms, rules, P, t, dur)
    else:
        P.start("asr", dur / RTFX["asr"], tr("Spracherkennung", "Speech recognition"))
        t0 = time.time(); r = _asr(wav, language, terms if cfg["glossary_prompt"] else None); t["asr"] = time.time() - t0
        replaced = glossary.apply(r["words"], rules)

        P.start("diarize", dur / RTFX["diarize"], tr("Sprechertrennung", "Speaker separation"))
        from . import diarize
        t0 = time.time()
        segs, clusters = diarize.diarize(wav, cfg["min_speakers"], cfg["max_speakers"], num_speakers)
        t["diarize"] = time.time() - t0
        words = assign_words(r["words"], segs)

    P.start("finish", msg=tr("Stimmen abgleichen", "Matching voices"))
    db = speakers.connect()
    old = speakers.release_job_refs(db, jid)       # Neuauswertung: eigene Referenzen nicht mit sich selbst abgleichen
    speakers.identify(db, clusters, cfg)
    speakers.carry_refs(db, jid, src, old, clusters, cfg)
    display_names(clusters, words)
    out_dir = Path(out_dir).expanduser().resolve() if out_dir else src.parent
    out_dir.mkdir(parents=True, exist_ok=True)     # --out mit neuem Ordner brach sonst erst beim Schreiben ab (96 %)
    stem = out_dir / src.stem
    doc = {"version": 1, "job_id": jid, "source": str(src), "created": time.strftime("%Y-%m-%d %H:%M"),
           "model": asr.MODEL, "language": language, "duration": dur, "tracks": info["tracks"], "track_mode": mode, "event": event,
           "track_relation": relation, "timing_s": {k: round(v, 1) for k, v in t.items()},
           "glossary": terms, "glossary_replacements": replaced, "speakers": [{k: v for k, v in c.items() if k != "embedding"} for c in clusters],
           "words": words, "diarization": segs, "overlaps": [[round(s, 2), round(e, 2)] for s, e in overlaps]}
    db.execute("DELETE FROM clusters WHERE job_id=?", (jid,))
    speakers.save_job(db, jid, src, f"{stem}.transcript.json", asr.MODEL, clusters)
    paths = render.write(doc, stem, formats)
    return doc, paths


def load_event(src):
    """Termin aus dem Kalender (von der App neben die Aufnahme gelegt): (event, Namen der anderen Teilnehmer)."""
    f = Path(src).with_name(Path(src).stem + ".event.json")
    if not f.exists():
        return None, []
    try:
        ev = json.loads(f.read_text())
    except ValueError:
        return None, []
    # Räume/Ressourcen sind keine Sprecher (ältere .event.json haben kein "type": Google-Ressourcenadresse)
    ev["attendees"] = [a for a in ev.get("attendees", []) if a.get("type", "person") == "person"
                       and "@resource.calendar.google.com" not in a.get("email", "")]
    others = [a["name"] for a in ev.get("attendees", []) if not a.get("me") and a.get("status") != "abgesagt" and a.get("name")]
    return ev, others


def load_doc(path):
    p = Path(path).expanduser()
    if p.suffix != ".json":
        p = p.with_name(p.stem.removesuffix(".transcript") + ".transcript.json")
    return json.loads(p.read_text()), p


def find_cluster(doc, who):
    """Sprecher über Buchstabe (B), pyannote-Label (SPEAKER_01), Anzeigenamen oder Namen finden."""
    w = speakers.norm_name(who).lower()
    w = w.removeprefix("sprecher ").removeprefix("speaker ").strip()   # alte (de) und neue (en) Anzeigenamen
    for c in doc["speakers"]:
        if w in (c["letter"].lower(), c["label"].lower(), c["display"].lower(), (c.get("name") or "").lower()):
            return c
    raise KeyError(tr("Sprecher", "Speaker") + f" {who!r} " + tr("nicht gefunden; vorhanden: ", "not found; available: ") + ", ".join(f"{c['letter']}={c['display']}" for c in doc["speakers"]))


def rerender(doc, json_path, formats=None):
    stem = Path(json_path).with_name(Path(json_path).name.removesuffix(".transcript.json"))
    return render.write(doc, stem, formats or config.load()["formats"])


def name_speaker(path, who, name):
    """Sprecher in einem Transkript benennen: Datenbank lernt die Stimme, Transkript wird neu geschrieben."""
    doc, jp = load_doc(path)
    c = find_cluster(doc, who)
    db = speakers.connect()
    name = speakers.resolve_name(db, name)
    stored = speakers.enroll(db, doc["job_id"], c["label"], name)
    c.update(name=name, status="bestätigt", person_id=speakers.person_id(db, name))
    display_names(doc["speakers"], doc["words"])
    return rerender(doc, jp), stored, c


def recheck(path):
    """Offene Stimmen eines fertigen Transkripts neu gegen die Stimmdatenbank abgleichen – ohne neu zu rechnen (die
    Cluster-Einbettungen liegen in der Datenbank). Nützlich, wenn seither Personen benannt wurden. Bestätigte bleiben;
    eine offene Stimme bekommt eine hier schon bestätigte Person nur, wenn sie sicher passt (aufgespaltene Stimme).
    Liefert die geänderten Sprecher."""
    doc, jp = load_doc(path)
    db = speakers.connect()
    cfg = config.load()
    vec = {r["label"]: speakers._vec(r["vec"]) for r in db.execute("SELECT label, vec FROM clusters WHERE job_id=?", (doc["job_id"],))}
    todo = [dict(c, embedding=vec[c["label"]]) for c in doc["speakers"] if c["status"] != "bestätigt" and c["label"] in vec]
    speakers.identify(db, todo, cfg)
    confirmed = {c.get("person_id") for c in doc["speakers"] if c["status"] == "bestätigt"}
    by = {c["label"]: c for c in doc["speakers"]}
    changed = []
    for n in todo:
        if n["person_id"] in confirmed and n["status"] != "sicher":
            n.update(person_id=None, name=None, score=None, status="unbekannt")
        c = by[n["label"]]
        before = (c.get("name"), c["status"])
        c.update({k: n[k] for k in ("person_id", "name", "score", "status", "candidates")})
        db.execute("UPDATE clusters SET person_id=?, score=?, status=? WHERE job_id=? AND label=?",
                   (c["person_id"], c["score"], c["status"], doc["job_id"], c["label"]))
        if (c["name"], c["status"]) != before:
            changed.append(c)
    db.commit()
    display_names(doc["speakers"], doc["words"])
    rerender(doc, jp)
    return changed


SIDECARS = (".md", ".srt", ".error.txt", ".event.json")


def clean_stem(name):
    """Dateiname aus einem Titel: keine Pfad-/Sonderzeichen, einfache Leerzeichen, höchstens 90 Zeichen."""
    import re
    import unicodedata
    name = unicodedata.normalize("NFC", name)
    name = re.sub(r'[/\\:*?"<>|\n\r\t]+', " ", name)
    name = re.sub(r"\s+", " ", name).strip(" .-_")
    return name[:90].rstrip(" .-_")


def rename(path, new_stem):
    """Aufnahme samt Transkript umbenennen: Audio, .transcript.json, .md, .srt; Verweise im Transkript, in der
    Stimmdatenbank (jobs, embeddings.source) und in den Statusdateien der App werden mitgezogen.
    Liefert die neuen Pfade. Läuft gerade eine Transkription dieser Datei (<name>.lock), wird abgebrochen."""
    doc, jp = load_doc(path)
    old_src = Path(doc["source"])
    stem = clean_stem(new_stem)
    if not stem:
        raise ValueError(tr("leerer Name", "empty name"))
    folder = old_src.parent if old_src.exists() else jp.parent
    old_stem = jp.name.removesuffix(".transcript.json")
    if stem == old_stem:
        return {"json": jp, "source": old_src}
    if (jp.parent / (old_stem + ".lock")).exists() or old_src.with_name(old_src.stem + ".lock").exists():
        raise RuntimeError(tr("Transkription dieser Datei läuft noch", "transcription of this file is still running"))
    base, n = stem, 2
    while (folder / (stem + old_src.suffix)).exists() or (jp.parent / (stem + ".transcript.json")).exists():
        stem = f"{base} {n}"; n += 1
    new_src = folder / (stem + old_src.suffix)
    # Erst die Begleitdateien, zuletzt das Audio: sieht der Wächter das Audio unter neuem Namen, liegt das Transkript
    # schon daneben (er wartet ohnehin 10 s, bevor er eine Datei anfasst).
    formats = [f for f, ext in (("md", ".md"), ("srt", ".srt")) if (jp.parent / (old_stem + ext)).exists()]
    doc["source"] = str(new_src)
    display_names(doc["speakers"], doc["words"])   # „Sprecher A“/„Speaker A“ in der aktuellen Ausgabesprache
    new_json = jp.parent / (stem + ".transcript.json")
    paths = render.write(doc, jp.parent / stem, formats)
    for ext in SIDECARS + (".transcript.json",):
        old = jp.parent / (old_stem + ext)
        if old.exists() and old != paths.get("json"):
            if ext in (".error.txt", ".event.json"):
                old.rename(jp.parent / (stem + ext))
            else:
                old.unlink()
    if old_src.exists():
        os.utime(new_json, None)               # Transkript bleibt jünger als das Audio (Wächter: „erledigt“)
        old_src.rename(new_src)
    _relink(doc["job_id"], old_src, new_src, paths)
    return {**paths, "source": new_src}


def _relink(jid, old_src, new_src, paths):
    """Verweise auf eine umbenannte/verschobene Aufnahme nachziehen: Stimmdatenbank und Statusdateien der App."""
    db = speakers.connect()
    with db:
        db.execute("UPDATE jobs SET source=?, transcript=? WHERE id=?", (str(new_src), str(paths["json"]), jid))
        db.execute("UPDATE embeddings SET source=? WHERE job_id=?", (str(new_src), jid))
    for f in config.JOBS.glob("*.json"):       # App-Liste: Quelle und Ergebnis zeigen auf die neuen Dateien
        try:
            st = json.loads(f.read_text())
        except (OSError, ValueError):
            continue
        if st.get("source") == str(old_src):
            st["source"] = str(new_src)
            if st.get("result"):
                st["result"] = {k: str(v) for k, v in paths.items()}
            f.write_text(json.dumps(st, ensure_ascii=False))


def find_moved(src, jid=None):
    """Im Finder umbenannte oder verschobene Aufnahme wiedererkennen: gleicher Inhalt (job_id = Inhalts-Hash) wie ein
    erledigter Auftrag, dessen Audio unter dem alten Pfad nicht mehr liegt, dessen Transkript aber noch. Liefert den
    Pfad des alten Transkripts oder None (auch bei einer Kopie – das Original liegt dann ja noch)."""
    src = Path(src).expanduser().resolve()
    r = speakers.connect().execute("SELECT source, transcript FROM jobs WHERE id=?", (jid or job_id(src),)).fetchone()
    if not r or not r["transcript"]:
        return None
    jp, old = Path(r["transcript"]), Path(r["source"])
    if old == src or old.exists() or not jp.exists():
        return None
    return jp


def adopt(src, jid=None):
    """Transkript samt Begleitdateien zu einer umbenannten/verschobenen Aufnahme holen statt neu zu rechnen (neuer Name
    und Ordner wie die Aufnahme); Stimmdatenbank und App-Liste werden mitgezogen. Liefert (doc, paths) oder None."""
    src = Path(src).expanduser().resolve()
    jp = find_moved(src, jid)
    if not jp:
        return None
    doc, _ = load_doc(jp)
    old_src, old_stem = Path(doc["source"]), jp.name.removesuffix(".transcript.json")
    dest = src.parent / src.stem
    formats = [f for f, ext in (("md", ".md"), ("srt", ".srt")) if (jp.parent / (old_stem + ext)).exists()]
    doc["source"] = str(src)
    display_names(doc["speakers"], doc["words"])
    paths = render.write(doc, dest, formats)
    for ext in SIDECARS + (".transcript.json",):
        old = jp.parent / (old_stem + ext)
        if old.exists() and old != paths.get("json"):
            if ext in (".error.txt", ".event.json"):
                old.rename(dest.with_name(dest.name + ext))
            else:
                old.unlink()
    _relink(doc["job_id"], old_src, src, paths)
    return doc, paths


def confirm(path):
    """Alle automatischen Zuordnungen eines Transkripts bestätigen (verbessert die Referenzen)."""
    doc, jp = load_doc(path)
    db = speakers.connect()
    done = []
    for c in doc["speakers"]:
        if c.get("name") and c["status"] in ("sicher", "vermutlich"):
            c["name"] = speakers.resolve_name(db, c["name"])
            speakers.enroll(db, doc["job_id"], c["label"], c["name"], origin="confirmed")
            c["status"] = "bestätigt"; done.append(c["name"])
    display_names(doc["speakers"], doc["words"])
    rerender(doc, jp)
    return done
