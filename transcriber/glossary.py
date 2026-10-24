"""Glossar: Namen und Fachbegriffe, eine Zeile je Begriff (Datei: config „vocab_file“).

    ACME = Akme, A.C.M.E.        Begriff = Schreibweisen, die nach der Erkennung durch den Begriff ersetzt werden
    Muster AG = Muster A G       auch mehrteilig
    Kundenzentrierung            ohne Varianten: nur Liste (Prompt, falls eingeschaltet)
    # Kommentar

Wirksam sind die Ersetzungen. Als Prompt für Whisper gehen die Begriffe nur mit config „glossary_prompt“ ein –
gemessen verschlechtert das die Erkennung (asr.py). Die Ersetzung ist fest und unabhängig von Groß-/Kleinschreibung,
greift nur auf ganze Wörter und behält Satzzeichen am Wortende."""
import re
import unicodedata

PUNCT = ".,;:!?…\"'“”„»«)("


def load(path):
    terms, rules = [], []
    if not path or not path.exists():
        return terms, rules
    for line in path.read_text().splitlines():
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        term, _, variants = line.partition("=")
        term = term.strip()
        terms.append(term)
        for v in variants.split(","):
            if v.strip():
                rules.append(([_key(t) for t in v.split()], term))
    rules.sort(key=lambda r: -len(r[0]))          # längere Varianten zuerst
    return terms, rules


def entries(path):
    """Einträge als [{"term", "variants"}] (für MCP und Anzeige)."""
    out = []
    if path and path.exists():
        for line in path.read_text().splitlines():
            line = line.split("#", 1)[0].strip()
            if line:
                term, _, variants = line.partition("=")
                out.append({"term": term.strip(), "variants": [v.strip() for v in variants.split(",") if v.strip()]})
    return out


def add(path, term, variants=()):
    """Begriff ergänzen. Gibt es ihn schon (Groß-/Kleinschreibung egal), kommen nur neue Schreibweisen in dieselbe
    Zeile – sonst eine neue Zeile. Andere Zeilen und Kommentare bleiben unverändert. Liefert (Eintrag, geändert)."""
    clean = lambda x: unicodedata.normalize("NFC", re.sub(r"[#=,\n]", "", x)).strip()
    term = clean(term)
    if not term:
        raise ValueError("leerer Begriff")
    new = [v for v in dict.fromkeys(clean(v) for v in variants) if v and v.lower() != term.lower()]
    lines = path.read_text().splitlines() if path.exists() else [
        "# Glossar für transcriber – Format: Begriff = Schreibweise1, Schreibweise2 (werden nach der Erkennung ersetzt)"]
    for i, line in enumerate(lines):
        body, hash_, comment = line.partition("#")
        t, _, vs = body.partition("=")
        if body.strip() and t.strip().lower() == term.lower():
            term, old = t.strip(), [v.strip() for v in vs.split(",") if v.strip()]
            new = [v for v in new if v.lower() not in {o.lower() for o in old}]
            if not new:
                return {"term": term, "variants": old}, False
            lines[i] = term + " = " + ", ".join(old + new) + (f"  {hash_}{comment}" if hash_ else "")
            break
    else:
        old = []
        lines.append(term + (" = " + ", ".join(new) if new else ""))
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(lines) + "\n")
    return {"term": term, "variants": old + new}, True


def _key(tok):
    return tok.strip(PUNCT).lower()


def apply(words, rules):
    """Ersetzt Varianten in der Wortliste (mit Zeitstempeln). Liefert Anzahl der Ersetzungen."""
    if not rules:
        return 0
    n, i = 0, 0
    while i < len(words):
        for pat, term in rules:
            k = len(pat)
            if [_key(w["w"]) for w in words[i:i + k]] == pat:
                last = words[i + k - 1]["w"]
                trail = last[len(last.rstrip(PUNCT)):]
                lead = words[i]["w"][: len(words[i]["w"]) - len(words[i]["w"].lstrip(PUNCT))]
                words[i] = dict(words[i], w=lead + term + trail, end=words[i + k - 1]["end"])
                del words[i + 1:i + k]
                n += 1
                break
        else:
            n += _apply_parts(words[i], rules)
        i += 1
    return n


def _apply_parts(word, rules):
    """Bindestrich-Wörter Teil für Teil: „Kali-Strategie“ → „KI-Strategie“ (nur einteilige Varianten)."""
    if "-" not in word["w"].strip("-"):
        return 0
    one = {pat[0]: term for pat, term in rules if len(pat) == 1}
    parts = word["w"].split("-")
    new = []
    for p in parts:
        core = p.strip(PUNCT)
        lead, trail = p[:len(p) - len(p.lstrip(PUNCT))], p[len(p.rstrip(PUNCT)):]
        new.append(lead + one[core.lower()] + trail if core and core.lower() in one else p)
    if new == parts:
        return 0
    word["w"] = "-".join(new)
    return 1


def apply_text(text, rules):
    for pat, term in rules:
        rx = r"(?<![\wäöüß])" + r"\s+".join(re.escape(p) for p in pat) + r"(?![\wäöüß])"
        text = re.sub(rx, term, text, flags=re.IGNORECASE)
    return text
