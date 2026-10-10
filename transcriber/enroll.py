"""Stimmreferenzen aus einem bereits benannten Transkript lernen (Markdown mit Zeilen „**[hh:mm:ss] Name:** …“).

Die Aufnahme wird neu diarisiert; jedes Cluster bekommt den Namen, der in seiner Sprechzeit überwiegt
(mindestens 60 % Anteil). Namen mit Zusatz „(vermutlich)“ gelten als unsicher und werden nicht gelernt,
„(Case Owner)“ u. ä. wird abgeschnitten."""
import json
import re
from collections import defaultdict
from pathlib import Path

from . import audio, config, speakers
from .i18n import t

ROW = re.compile(r"\*\*\[(\d\d):(\d\d):(\d\d)\] ([^:*]+):\*\*")


def parse_named(md):
    rows = []
    for line in Path(md).read_text().splitlines():
        m = ROW.match(line)
        if m:
            t = int(m[1]) * 3600 + int(m[2]) * 60 + int(m[3])
            raw = m[4].strip()
            unsure = "vermutlich" in raw or "?" in raw
            rows.append((t, re.sub(r"\s*\(.*?\)\s*", "", raw).strip(), unsure))
    return rows


def from_named_transcript(src, md, dry=False, cfg=None, share_min=0.6):
    from . import diarize, pipeline
    cfg = cfg or config.load()
    config.offline_env()
    src = Path(src).expanduser().resolve()
    jid = pipeline.job_id(src)
    wav = config.CACHE / jid / "audio.wav"
    if not wav.exists():
        audio.prepare(src, wav)
    segs, clusters = diarize.diarize(wav, cfg["min_speakers"], cfg["max_speakers"])
    rows = parse_named(md)
    ivs = [(t, rows[i + 1][0] if i + 1 < len(rows) else 1e9, name, uns) for i, (t, name, uns) in enumerate(rows)]
    ov = defaultdict(lambda: defaultdict(float))
    for s in segs:
        for a, b, name, uns in ivs:
            o = min(s["end"], b) - max(s["start"], a)
            if o > 0:
                ov[s["speaker"]][(name, uns)] += o
    db = speakers.connect()
    if not dry:
        db.execute("DELETE FROM clusters WHERE job_id=?", (jid,))
        speakers.save_job(db, jid, src, str(md), "enroll", clusters)
    summary = []
    for c in sorted(clusters, key=lambda c: -c["speech_s"]):
        tot = sum(ov[c["label"]].values()) or 1
        (name, uns), best = max(ov[c["label"]].items(), key=lambda kv: kv[1]) if ov[c["label"]] else (("?", True), 0)
        share = best / tot
        ok = share >= share_min and not uns and c["speech_s"] >= cfg["min_enroll_s"]
        stored = speakers.enroll(db, jid, c["label"], name, origin="enrolled") if ok and not dry else False
        summary.append({"label": c["label"], "speech_s": c["speech_s"], "name": name, "share": round(share, 2),
                        "unsure": uns, "stored": stored})
        print(f"  {c['label']}  {c['speech_s'] / 60:5.1f} min  → {name:10s} " + t("Anteil", "share") + f" {share:4.0%}"
              + (t("  (vermutlich, nicht gelernt)", "  (probably, not learned)") if uns else "")
              + (t("  gespeichert", "  stored") if stored else ""))
    out = config.DATA / "enroll" / f"{jid}.json"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps({"job_id": jid, "source": str(src), "named": str(md), "clusters": summary}, ensure_ascii=False, indent=1))
    return summary
