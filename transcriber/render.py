"""Ausgabe: Markdown (lesbar), JSON (vollständig, maschinenlesbar), optional SRT."""
import json
from pathlib import Path

from .i18n import status, t


def ts(x, srt=False):
    h, m, s = int(x // 3600), int(x % 3600 // 60), x % 60
    return f"{h:02d}:{m:02d}:{s:06.3f}".replace(".", ",") if srt else f"{h:02d}:{m:02d}:{int(s):02d}"


def mmss(x):
    return f"{int(x // 60)}:{int(x % 60):02d}"


def _turns(doc):
    names = {c["label"]: c["display"] for c in doc["speakers"]}
    out = []
    for w in doc["words"]:
        who = names.get(w.get("speaker"), t("Unklar", "Unclear"))
        if out and out[-1]["who"] == who and w["start"] - out[-1]["end"] < 5:
            out[-1]["text"] += " " + w["w"]; out[-1]["end"] = w["end"]
        else:
            out.append({"who": who, "start": w["start"], "end": w["end"], "text": w["w"]})
    return out


def markdown(doc, json_name):
    L = [f"# {Path(doc['source']).stem}", "",
         t("Quelle", "Source") + f": {Path(doc['source']).name} · {mmss(doc['duration'])} min · {doc['tracks']} "
         + t("Tonspur(en)", "audio track(s)") + "  ",
         t("Erstellt", "Created") + f": {doc['created']} · " + t("Modell", "Model") + f": {doc['model']} · "
         + t("Sprecher", "Speakers") + ": pyannote community-1", ""]
    ev = doc.get("event")
    others = [a["name"] for a in (ev or {}).get("attendees", []) if not a.get("me") and a.get("status") != "abgesagt"]
    if ev:
        L[-1:] = [t("Termin", "Event") + f": {ev.get('title') or '–'}"
                  + (" · " + t("Teilnehmer", "Attendees") + f": {', '.join(others)}" if others else "") + "  ", ""]
    L += [
         t("| Sprecher | Sprechzeit | Zuordnung |", "| Speaker | Speaking time | Match |"), "|---|---|---|"]
    unknown = False
    for c in sorted(doc["speakers"], key=lambda c: -c["speech_s"]):
        if c["status"] in ("sicher", "bestätigt"):
            z = status(c["status"]) + (f" ({c['score']:.2f})" if c.get("score") else "")
        elif c["status"] == "vermutlich":
            z = status("vermutlich") + f" ({c['score']:.2f}" + (t(", wenig Sprechzeit", ", little speaking time")
                                                                 if c["speech_s"] < 60 else "") + ")"
        else:
            unknown = True
            best = c.get("candidates") or []
            # Vergleich über den Vornamen: Kalender liefert evtl. nur „Kim“, die Stimmdatenbank „Kim Beispiel“
            named = {x["name"].split()[0].lower() for x in doc["speakers"] if x.get("name")}
            free = [n for n in others if n.split()[0].lower() not in named]
            z = status("unbekannt") + (t(" – am ähnlichsten: ", " – most similar: ") + f"{best[0][0]} ({best[0][1]:.2f})"
                                       if best else "") \
                + (t(" – laut Kalender dabei: ", " – in calendar: ") + ", ".join(free) if free else "")
        L.append(f"| {c['display']} | {mmss(c['speech_s'])} | {z} |")
    if unknown or any(c["status"] == "vermutlich" for c in doc["speakers"]):
        L += ["", t("Benennen", "Name a speaker") + f": `transcriber name \"{json_name}\" " + t("<Buchstabe> <Name>", "<letter> <name>")
                  + "` · " + t("alle Zuordnungen bestätigen", "confirm all matches") + f": `transcriber confirm \"{json_name}\"`"]
    L.append("")
    for u in _turns(doc):
        L += [f"**[{ts(u['start'])}] {u['who']}:** {u['text']}", ""]
    return "\n".join(L)


def srt(doc, max_s=7.0, max_chars=84):
    names = {c["label"]: c["display"] for c in doc["speakers"]}
    cues, cur = [], None
    for w in doc["words"]:
        who = names.get(w.get("speaker"), t("Unklar", "Unclear"))
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
