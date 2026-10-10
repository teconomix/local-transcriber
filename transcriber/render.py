"""Ausgabe: Markdown (lesbar), JSON (vollständig, maschinenlesbar), optional SRT."""
import json
from pathlib import Path


def ts(x, srt=False):
    h, m, s = int(x // 3600), int(x % 3600 // 60), x % 60
    return f"{h:02d}:{m:02d}:{s:06.3f}".replace(".", ",") if srt else f"{h:02d}:{m:02d}:{int(s):02d}"


def mmss(x):
    return f"{int(x // 60)}:{int(x % 60):02d}"


def _turns(doc):
    names = {c["label"]: c["display"] for c in doc["speakers"]}
    out = []
    for w in doc["words"]:
        who = names.get(w.get("speaker"), "Unklar")
        if out and out[-1]["who"] == who and w["start"] - out[-1]["end"] < 5:
            out[-1]["text"] += " " + w["w"]; out[-1]["end"] = w["end"]
        else:
            out.append({"who": who, "start": w["start"], "end": w["end"], "text": w["w"]})
    return out


def markdown(doc, json_name):
    L = [f"# {Path(doc['source']).stem}", "",
         f"Quelle: {Path(doc['source']).name} · {mmss(doc['duration'])} min · {doc['tracks']} Tonspur(en)  ",
         f"Erstellt: {doc['created']} · Modell: {doc['model']} · Sprecher: pyannote community-1", ""]
    ev = doc.get("event")
    others = [a["name"] for a in (ev or {}).get("attendees", []) if not a.get("me") and a.get("status") != "abgesagt"]
    if ev:
        L[-1:] = [f"Termin: {ev.get('title') or '–'}" + (f" · Teilnehmer: {', '.join(others)}" if others else "") + "  ", ""]
    L += [
         "| Sprecher | Sprechzeit | Zuordnung |", "|---|---|---|"]
    unknown = False
    for c in sorted(doc["speakers"], key=lambda c: -c["speech_s"]):
        if c["status"] in ("sicher", "bestätigt"):
            z = c["status"] + (f" ({c['score']:.2f})" if c.get("score") else "")
        elif c["status"] == "vermutlich":
            z = f"vermutlich ({c['score']:.2f}" + (", wenig Sprechzeit" if c["speech_s"] < 60 else "") + ")"
        else:
            unknown = True
            best = c.get("candidates") or []
            # Vergleich über den Vornamen: Kalender liefert evtl. nur „Kim“, die Stimmdatenbank „Kim Beispiel“
            named = {x["name"].split()[0].lower() for x in doc["speakers"] if x.get("name")}
            free = [n for n in others if n.split()[0].lower() not in named]
            z = "unbekannt" + (f" – am ähnlichsten: {best[0][0]} ({best[0][1]:.2f})" if best else "") \
                + (f" – laut Kalender dabei: {', '.join(free)}" if free else "")
        L.append(f"| {c['display']} | {mmss(c['speech_s'])} | {z} |")
    if unknown or any(c["status"] == "vermutlich" for c in doc["speakers"]):
        L += ["", f"Benennen: `transcriber name \"{json_name}\" <Buchstabe> <Name>` · "
                  f"alle Zuordnungen bestätigen: `transcriber confirm \"{json_name}\"`"]
    L.append("")
    for t in _turns(doc):
        L += [f"**[{ts(t['start'])}] {t['who']}:** {t['text']}", ""]
    return "\n".join(L)


def srt(doc, max_s=7.0, max_chars=84):
    names = {c["label"]: c["display"] for c in doc["speakers"]}
    cues, cur = [], None
    for w in doc["words"]:
        who = names.get(w.get("speaker"), "Unklar")
        ends = w["w"][-1:] in ".?!"
        fits = w["end"] - cur["start"] <= max_s and len(cur["text"]) + len(w["w"]) < max_chars if cur else False
        fits = fits or (cur and ends and len(cur["text"]) + len(w["w"]) < max_chars + 20)  # Satzende noch mitnehmen
        if cur and cur["who"] == who and fits and not (len(cur["text"]) > 42 and cur["text"][-1:] in ".?!"):
            cur["text"] += " " + w["w"]; cur["end"] = w["end"]
        else:
            cur = {"who": who, "start": w["start"], "end": w["end"], "text": w["w"]}; cues.append(cur)
    return "\n".join(f"{i}\n{ts(c['start'], True)} --> {ts(c['end'], True)}\n{c['who']}: {c['text']}\n"
                     for i, c in enumerate(cues, 1))


def write(doc, stem, formats):
    stem = Path(stem)
    paths = {}
    jp = stem.with_name(stem.name + ".transcript.json")
    jp.write_text(json.dumps(doc, ensure_ascii=False, indent=1, default=float))
    paths["json"] = jp
    if "md" in formats:
        p = stem.with_name(stem.name + ".md"); p.write_text(markdown(doc, jp.name)); paths["md"] = p
    if "srt" in formats:
        p = stem.with_name(stem.name + ".srt"); p.write_text(srt(doc)); paths["srt"] = p
    return paths
