"""Glossar: Namen und Fachbegriffe, eine Zeile je Begriff (Datei: config „vocab_file“).

    ACME = Akme, A.C.M.E.        Begriff = Schreibweisen, die nach der Erkennung durch den Begriff ersetzt werden
    Muster AG = Muster A G       auch mehrteilig
    Kundenzentrierung            ohne Varianten: nur Liste (Prompt, falls eingeschaltet)
    # Kommentar

Wirksam sind die Ersetzungen. Als Prompt für Whisper gehen die Begriffe nur mit config „glossary_prompt“ ein –
gemessen verschlechtert das die Erkennung (asr.py). Die Ersetzung ist fest und unabhängig von Groß-/Kleinschreibung,
greift nur auf ganze Wörter und behält Satzzeichen am Wortende."""
import re

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
        i += 1
    return n


def apply_text(text, rules):
    for pat, term in rules:
        rx = r"(?<![\wäöüß])" + r"\s+".join(re.escape(p) for p in pat) + r"(?![\wäöüß])"
        text = re.sub(rx, term, text, flags=re.IGNORECASE)
    return text
