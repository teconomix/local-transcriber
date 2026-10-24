"""Ausgabe: lesbares Transkript als Markdown (.md) oder reiner Text (.txt, Einstellung text_format), JSON (vollständig,
maschinenlesbar), optional SRT. Im Aufrufer heißt das lesbare Transkript immer „md“ (formats, paths), egal welche Endung."""
import json
import unicodedata
from pathlib import Path

from . import config
from .i18n import status, t

TEXT_EXT = {"md": ".md", "txt": ".txt"}


def ts(x, srt=False):
    h, m, s = int(x // 3600), int(x % 3600 // 60), x % 60
    return f"{h:02d}:{m:02d}:{s:06.3f}".replace(".", ",") if srt else f"{h:02d}:{m:02d}:{int(s):02d}"


def mmss(x):
    return f"{int(x // 60)}:{int(x % 60):02d}"


def _turns(doc):
    """Redebeiträge in zeitlicher Folge. In Bereichen gleichzeitigen Sprechens (doc["overlaps"], von der
    Spurauswertung erkannt) je Sprecher ein zusammenhängender Beitrag statt Wort-für-Wort-Wechsel; schneller Dialog
    nacheinander bleibt so, wie er war (der steht in keinem dieser Bereiche)."""
    names = {c["label"]: c["display"] for c in doc["speakers"]}
    regions = doc.get("overlaps") or []
    region = lambda w: next((i for i, (s, e) in enumerate(regions) if s <= (w["start"] + w["end"]) / 2 < e), None)
    out, current = [], {}                     # current: (Sprecher, Bereich) → laufender Beitrag
    for w in doc["words"]:
        who = names.get(w.get("speaker"), t("Unklar", "Unclear"))
        r = region(w)
        if r is not None and (who, r) in current:
            u = current[(who, r)]
            u["text"] += " " + w["w"]; u["end"] = w["end"]
            continue
        if out and out[-1]["who"] == who and w["start"] - out[-1]["end"] < 5:
            out[-1]["text"] += " " + w["w"]; out[-1]["end"] = w["end"]
        else:
            out.append({"who": who, "start": w["start"], "end": w["end"], "text": w["w"]})
        if r is not None:
            current[(who, r)] = out[-1]
    return out


def markdown(doc, json_name, plain=False):
    """plain=True: dieselben Angaben ohne Markdown-Zeichen (für .txt) – Sprecherliste als Zeilen statt Tabelle."""
    L = [Path(doc["source"]).stem if plain else f"# {Path(doc['source']).stem}", "",
         t("Quelle", "Source") + f": {Path(doc['source']).name} · {mmss(doc['duration'])} min · {doc['tracks']} "
         + t("Tonspur(en)", "audio track(s)") + "  ",
         t("Erstellt", "Created") + f": {doc['created']} · " + t("Modell", "Model") + f": {doc['model']} · "
         + t("Sprecher", "Speakers") + ": pyannote community-1"
         + (" · " + t("Sprache", "Language") + f": {doc['language']} ("
            + t("erkannt, eingestellt war", "detected, setting was") + f" {doc['language_set']})" if doc.get("language_set") else ""),
         ""]
    ev = doc.get("event")
    others = [a["name"] for a in (ev or {}).get("attendees", []) if not a.get("me") and a.get("status") != "abgesagt"]
    if ev:
        L[-1:] = [t("Termin", "Event") + f": {ev.get('title') or '–'}"
                  + (" · " + t("Teilnehmer", "Attendees") + f": {', '.join(others)}" if others else "") + "  ", ""]
    L += [t("Sprecher", "Speakers") + ":"] if plain else [
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
        L.append(f"  {c['display']} – {mmss(c['speech_s'])} min – {z}" if plain else f"| {c['display']} | {mmss(c['speech_s'])} | {z} |")
    if unknown or any(c["status"] == "vermutlich" for c in doc["speakers"]):
        q = "" if plain else "`"
        L += ["", t("Benennen", "Name a speaker") + f": {q}transcriber name \"{json_name}\" " + t("<Buchstabe> <Name>", "<letter> <name>")
                  + f"{q} · " + t("alle Zuordnungen bestätigen", "confirm all matches") + f": {q}transcriber confirm \"{json_name}\"{q}"]
    L.append("")
    for u in _turns(doc):
        L += [f"[{ts(u['start'])}] {u['who']}: {u['text']}" if plain else f"**[{ts(u['start'])}] {u['who']}:** {u['text']}", ""]
    text = "\n".join(L)
    return text.replace("  \n", "\n") if plain else text   # zwei Leerzeichen = Markdown-Zeilenumbruch


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


def is_ours(path, source_name):
    """Ist <path> ein von uns geschriebenes lesbares Transkript zu dieser Aufnahme? Neben Aufnahmen liegen auch fremde
    Dateien gleichen Namens (eigene Notizen als .txt, bei manchen Nutzern Notendateien als .md) – die dürfen weder
    überschrieben noch gelöscht werden. Erkennungszeichen: „Quelle: <Audiodatei> ·“ bzw. „Source: …“ im Kopf."""
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return is_ours_text(f.read(1500), source_name)
    except OSError:
        return False


def is_ours_text(head, source_name):
    # Unicode-Form angleichen: Namen vom Handy (Syncthing) liegen als NFD auf der Platte, getippte Pfade (CLI, MCP) sind
    # NFC – sonst galt das eigene Transkript als fremd und es entstand <name>.transcript.txt daneben (2026-10-24).
    nfc = lambda x: unicodedata.normalize("NFC", x)
    return any(f"{word}: {nfc(source_name)} · " in nfc(head[:1500]) for word in ("Quelle", "Source"))


def find_readable(stem, source_name):
    """Eigenes lesbares Transkript zu <stem> (auch die Ausweichform <stem>.transcript.md/.txt, siehe write) als
    (Pfad, Format) oder (None, None)."""
    stem = Path(stem)
    for fmt, ext in TEXT_EXT.items():
        for p in (stem.with_name(stem.name + ext), stem.with_name(stem.name + ".transcript" + ext)):
            if is_ours(p, source_name):
                return p, fmt
    return None, None


def write(doc, stem, formats, text_format=None):
    """text_format: "md"/"txt"; ohne Angabe das Format des vorhandenen eigenen Transkripts (Neu auswerten, Benennen
    behalten es bei), sonst die Einstellung text_format."""
    stem = Path(stem)
    paths = {}
    jp = stem.with_name(stem.name + ".transcript.json")
    jp.write_text(json.dumps(doc, ensure_ascii=False, indent=1, default=float))
    paths["json"] = jp
    if "md" in formats:
        src_name = Path(doc["source"]).name
        fmt = text_format or find_readable(stem, src_name)[1] or config.load().get("text_format", "txt")
        fmt = fmt if fmt in TEXT_EXT else "md"
        p = stem.with_name(stem.name + TEXT_EXT[fmt])
        if p.exists() and not is_ours(p, src_name):
            # fremde Datei gleichen Namens: nicht überschreiben, eigenes Transkript daneben ablegen
            p = stem.with_name(stem.name + ".transcript" + TEXT_EXT[fmt])
        p.write_text(markdown(doc, jp.name, plain=fmt == "txt")); paths["md"] = p
    if "srt" in formats:
        p = stem.with_name(stem.name + ".srt"); p.write_text(srt(doc)); paths["srt"] = p
    return paths
