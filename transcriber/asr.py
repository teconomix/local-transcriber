"""Spracherkennung mit Whisper large-v3-turbo (mlx-community/whisper-large-v3-turbo, FP16, aus dem HF-Cache).

Modellwahl 2026-10-09 nach Vergleich mit gehörter Referenz (bench/ERGEBNIS.md): turbo vor Parakeet und Qwen3-ASR;
large-v3 entfernt (2,5× langsamer, ungenauere Wortzeiten). Rückgabe: {"text", "words": [{w, start, end, p}], "segments"}.

Zwei Modelle (config „asr_model“): turbo in FP16 oder in 8 Bit. 8 Bit gemessen gleich genau (WER 9,9 % wie FP16;
2026-10-27 auf 70 Aufnahmen gegen large-v3 als Schiedsrichter gleichauf, bench/Q8.md), 0,86 statt 1,61 GB Platte,
Metal-Spitze 1,8 statt 2,6 GB → Standard für neue Installationen. Bestehende (FP16 liegt, 8 Bit nicht, nichts
eingestellt) bleiben bei FP16 – kein erzwungener Wechsel. 4 Bit kostete +2,3 Punkte und wird nicht angeboten."""
import os
import re
from pathlib import Path

from . import config

# Name → (Hugging-Face-Repo, Kurzname fürs Transkript und den Zwischenspeicher-Schlüssel)
MODELS = {"turbo": ("mlx-community/whisper-large-v3-turbo", "whisper-turbo"),
          "turbo-8bit": ("mlx-community/whisper-large-v3-turbo-8bit", "whisper-turbo-8bit")}
DEFAULT = "turbo-8bit"          # neue Installationen
FP16 = "turbo"                  # liegt direkt im HF-Cache, braucht keinen Ordner mit Verweisen
# Alle Sprachcodes, die Whisper kennt (mlx_whisper.tokenizer.LANGUAGES); welche die App anbietet, stellt man dort ein.
LANGUAGES = ("en zh de es ru ko fr ja pt tr pl ca nl ar sv it id hi fi vi he uk el ms cs ro da hu ta no th ur hr bg lt "
             "la mi ml cy sk te fa lv bn sr az sl kn et mk br eu is hy ne mn bs kk sq sw gl mr pa si km sn yo so af "
             "oc ka be tg sd gu am yi lo uz fo ht ps tk nn mt sa lb my bo tl mg as tt haw ln ha ba jw su yue").split()


def choice(cfg=None):
    """Eingestelltes Modell (config „asr_model“). Nichts eingestellt: FP16, wenn nur das schon geladen ist (bestehende
    Installation vor 0.10), sonst der Standard 8 Bit."""
    k = (cfg or config.load()).get("asr_model")
    if k in MODELS:
        return k
    return FP16 if installed(FP16) and not installed(DEFAULT) else DEFAULT


def name(cfg=None):
    return MODELS[choice(cfg)][1]


def local_dir(key):
    return config.DATA / "models" / MODELS[key][0].split("/")[1]


def path(cfg=None):
    """Was mlx_whisper als path_or_hf_repo bekommt. FP16: das Repo im HF-Cache. 8 Bit: ein Ordner unter DATA/models,
    denn mlx-community/…-8bit ist für mlx-audio-plus abgelegt (model.safetensors), mlx-whisper 0.4.3 lädt nur
    weights.safetensors/weights.npz. Die Gewichte sind bitgleich mit nn.quantize(bits=8, group_size=64) des
    FP16-Modells (1053/1053 Tensoren verglichen) – nur der Dateiname passt nicht. prepare() legt Verweise an."""
    key = choice(cfg)
    if key == FP16:
        return MODELS[key][0]
    d = local_dir(key)
    if not (d / "weights.safetensors").exists():
        prepare(key, download=False)
    return str(d)


def installed(key):
    """Liegt das Modell lokal (ohne Netz prüfbar)?"""
    from huggingface_hub import snapshot_download
    try:
        snapshot_download(MODELS[key][0], local_files_only=True)
        return True
    except Exception:  # noqa: BLE001 – LocalEntryNotFoundError & Co.: nicht vorhanden
        return False


def remove(key):
    """Nicht genutztes Modell löschen: aus dem HF-Cache und für 8 Bit den Ordner mit Verweisen. Das eingestellte Modell
    und während einer laufenden Transkription (run.lock) nicht. Gibt die freigegebenen Bytes zurück.
    Über scan_cache_dir statt rmtree: huggingface_hub 2.x legt die Gewichte im gemeinsamen Speicher hub/blobs/<xx>/
    ab, der Repo-Ordner enthält nur Verweise – rmtree gab den Platz nicht frei (gesehen 2026-10-27)."""
    import fcntl
    import shutil
    from huggingface_hub import scan_cache_dir
    from huggingface_hub.constants import HF_HUB_CACHE
    from .i18n import t
    if key == choice():
        raise RuntimeError(t("das eingestellte Modell lässt sich nicht löschen – erst wechseln",
                             "the selected model cannot be deleted – switch first"))
    lock = config.DATA / "run.lock"
    if lock.exists():
        with open(lock) as f:
            try:
                fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
                fcntl.flock(f, fcntl.LOCK_UN)
            except BlockingIOError:
                raise RuntimeError(t("Transkription läuft – später löschen", "transcription running – delete later")) from None
    freed = 0
    if Path(HF_HUB_CACHE).is_dir():
        info = scan_cache_dir(HF_HUB_CACHE)
        for repo in (r for r in info.repos if r.repo_id == MODELS[key][0]):
            plan = info.delete_revisions(*(v.commit_hash for v in repo.revisions))
            freed += plan.expected_freed_size
            plan.execute()
            shutil.rmtree(repo.repo_path, ignore_errors=True)   # Reste ohne Revision (abgebrochener Download)
    shutil.rmtree(local_dir(key), ignore_errors=True)
    return freed


def prepare(key, download=False):
    """Modell bereitstellen: aus dem HF-Cache (download=True: vorher laden) und für 8 Bit den Ordner mit Verweisen
    (weights.safetensors → model.safetensors, config.json) unter DATA/models anlegen. Fehler mit Hinweis, wenn es
    fehlt – zur Laufzeit gilt HF_HUB_OFFLINE=1."""
    from huggingface_hub import snapshot_download
    from .i18n import t
    repo = MODELS[key][0]
    try:
        snap = Path(snapshot_download(repo, local_files_only=not download))
    except Exception as e:  # noqa: BLE001
        raise RuntimeError(t(f"Spracherkennungsmodell {repo} ist nicht geladen – „transcriber model {key} --download“",
                             f"speech recognition model {repo} is not downloaded – run \"transcriber model {key} --download\"")) from e
    if key == FP16:
        return snap
    d = local_dir(key)
    d.mkdir(parents=True, exist_ok=True)
    for dst, src in (("weights.safetensors", "model.safetensors"), ("config.json", "config.json")):
        target, link = (snap / src).resolve(), d / dst
        if link.is_symlink() or link.exists():
            if link.resolve() == target:
                continue
            link.unlink()
        os.symlink(target, link)
    return d


def _prompt(terms, language):
    if not terms:
        return None
    head = {"de": "Gespräch auf Deutsch. Namen und Begriffe: ",
            "en": "Conversation in English. Names and terms: "}.get(language, "")
    return head + ", ".join(terms) + "."


def detect_language(wav, windows=8, min_share=0.75, min_p=0.8):
    """Welche Sprache wird gesprochen? Whispers Spracherkennung auf `windows` gleichmäßig verteilten 30-s-Fenstern
    (stille übersprungen). Liefert (Sprache, Anteil der Fenster) – Sprache nur, wenn mindestens min_share der
    Fenster sie mit Wahrscheinlichkeit ≥ min_p erkennen, sonst None (gemischt oder unklar).
    Anlass 2026-10-19: Sprache im Panel auf Englisch vergessen, deutsches Gespräch → Whisper übersetzte es größtenteils
    ins Englische. Gemessen an drei Calls: 8/8 Fenster richtig (p 0,90–1,00), 2 s je Aufnahme."""
    from collections import Counter
    import mlx.core as mx
    import numpy as np
    import soundfile as sf
    from mlx_whisper.audio import N_FRAMES, N_SAMPLES, log_mel_spectrogram, pad_or_trim
    from mlx_whisper.transcribe import ModelHolder
    a, _ = sf.read(str(wav), dtype="float32")
    if a.ndim > 1:
        a = a.mean(axis=1)
    model = ModelHolder.get_model(path(), mx.float16)     # derselbe Zwischenspeicher wie mlx_whisper.transcribe
    tops = []
    for k in range(1, windows + 1):
        x = a[int(len(a) * k / (windows + 1)):][:N_SAMPLES]
        if len(x) < N_SAMPLES // 3 or float(np.sqrt(np.mean(x ** 2))) < 0.003:
            continue
        mel = pad_or_trim(log_mel_spectrogram(x, n_mels=model.dims.n_mels), N_FRAMES, axis=-2).astype(mx.float16)
        _, probs = model.detect_language(mel)
        p = probs[0] if isinstance(probs, list) else probs
        lang, pr = max(p.items(), key=lambda kv: kv[1])
        tops.append((lang, pr))
    if len(tops) < 3:
        return None, 0.0
    lang, _ = Counter(l for l, _ in tops).most_common(1)[0]
    share = sum(1 for l, pr in tops if l == lang and pr >= min_p) / len(tops)
    return (lang if share >= min_share else None), round(share, 2)


# Neu-Dekodieren auffälliger Stellen (repair): kurzer Beispielsatz mit Satzzeichen als Prompt. Nur für Sprachen mit
# Groß-/Kleinschreibung und Satzzeichen, für die ein Satz hinterlegt ist; sonst bleibt alles, wie es ist.
STYLE_PROMPT = {"de": "Hallo, wie geht es dir? Gut, danke. Wir sprechen heute über das Thema.",
                "en": "Hello, how are you? Fine, thanks. Today we will talk about the topic."}
REPAIR = 1   # Fassung der Neu-Dekodierung – Teil des Zwischenspeicher-Schlüssels (pipeline._asr)
_ENDS = ".,?!"


def _flat_spans(segs, min_words=25):
    """Stellen, an denen Whisper ohne Satzzeichen und Großschreibung weiterschreibt: aufeinanderfolgende Segmente ohne
    . , ? ! und klein beginnend, zusammen ≥ min_words Wörter. Kommt fensterweise vor (30-s-Fenster), je nachdem, wo
    die Fenstergrenze liegt – derselbe Ausschnitt einzeln transkribiert ist oft wieder normal (2026-10-24)."""
    spans, run = [], []
    for s in list(segs) + [{"text": "X.", "start": 0.0, "end": 0.0}]:
        t = s["text"].strip()
        if t and not re.search(r"[.?!,]", t) and t[0].islower():
            run.append(s); continue
        if sum(len(x["text"].split()) for x in run) >= min_words:
            spans.append((run[0]["start"], run[-1]["end"]))
        run = []
    return spans


def accept(old, new, min_sim=0.6):
    """Neue Fassung einer Stelle nur nehmen, wenn sie dasselbe sagt (Wortfolge ≥ min_sim gleich, Länge 75–133 %),
    Whisper nicht unsicherer ist (mittleres p höchstens 0,02 schlechter) und es merklich mehr Satzzeichen gibt.
    Ohne diese Prüfung wurden in Tests aus 51 echten Wörtern „Ja, genau.“, eine englische Passage ins Deutsche
    übersetzt und in Rauschen „Vielen Dank.“ erfunden (bench/NEUDEKODIEREN.md)."""
    import difflib
    if not old or not new:
        return False, 0.0
    norm = lambda ws: [x for x in (w["w"].lower().strip(".,!?;:…\"'-") for w in ws) if x]
    p = lambda ws: sum(w["p"] or 0 for w in ws) / len(ws)
    pu = lambda ws: sum(1 for w in ws if w["w"][-1:] in _ENDS) / len(ws)
    sim = difflib.SequenceMatcher(None, norm(old), norm(new)).ratio()
    ok = sim >= min_sim and 0.75 <= len(new) / len(old) <= 1.33 and p(new) >= p(old) - 0.02 and pu(new) > pu(old) + 0.05
    return ok, round(sim, 2)


_THANKS = re.compile(r"(?i)^(vielen dank|danke( schön)?|thank you|thanks)[.!]?$")


def _strip_thanks(ws):
    """Whisper hängt an neu erkannte Stücke gern ein erfundenes „Vielen Dank.“ an (2 von 166 übernommenen Stellen,
    2026-10-24) → am Ende weg. Ein echtes Danke steht in der alten Fassung auch und fällt bei accept() nicht ins Gewicht."""
    for k in (3, 2, 1):
        if len(ws) > k and _THANKS.match(" ".join(w["w"] for w in ws[-k:])):
            return ws[:-k]
    return ws


def repair(wav, r, language):
    """Auffällige Stellen (_flat_spans) einzeln mit Stil-Prompt neu erkennen und übernehmen, wenn accept() zustimmt.
    Ändert r["words"]; Rückgabe: Liste der geprüften Stellen (start, end, sim, accepted) fürs Transkript."""
    prompt = STYLE_PROMPT.get(language)
    spans = _flat_spans(r["segments"]) if prompt else []
    if not spans:
        return []
    import mlx_whisper
    import soundfile as sf
    a, sr = sf.read(str(wav), dtype="float32")
    if a.ndim > 1:
        a = a.mean(axis=1)
    out = []
    for s, e in spans:
        lo = max(s - 0.3, 0.0)
        o = mlx_whisper.transcribe(a[int(lo * sr):int((e + 0.3) * sr)], path_or_hf_repo=path(), language=language,
                                   verbose=None, condition_on_previous_text=False, word_timestamps=True,
                                   initial_prompt=prompt)
        new = _strip_thanks([w for w in _words(o, lo) if s - 0.2 <= w["start"] < e + 0.2])
        inside = lambda w: s - 0.01 <= w["start"] < e + 0.01
        old = [w for w in r["words"] if inside(w)]
        ok, sim = accept(old, new)
        if ok:
            i = next(k for k, w in enumerate(r["words"]) if inside(w))
            r["words"] = r["words"][:i] + new + [w for w in r["words"][i:] if not inside(w)]
        out.append({"start": round(s, 2), "end": round(e, 2), "sim": sim, "accepted": ok})
    return out


# „\ufffd“: Whisper teilt manche Zeichen auf mehrere Token, am Ende bleibt ein halbes UTF-8-Zeichen übrig
# (2026-10-20: ein Name mit „��“ am Ende) → entfernen.
_clean = lambda x: x.replace("\ufffd", "").strip()


def _words(r, offset=0.0):
    return [{"w": _clean(w["word"]), "start": w["start"] + offset, "end": w["end"] + offset, "p": w.get("probability")}
            for s in r["segments"] for w in s.get("words", []) if _clean(w["word"])]


def transcribe(wav, terms=None, language="de"):
    """terms: Glossarbegriffe als Prompt – nur wenn config „glossary_prompt“ an ist. Gemessen 2026-10-09: Prompt im
    ersten Fenster WER 9,9 → 10,8 %, in jedem Fenster 15,5 % plus ausgelassene Halbsätze. Deshalb Standard aus;
    das Glossar wirkt über feste Ersetzungen (glossary.apply)."""
    import mlx_whisper
    from .i18n import t
    if language not in LANGUAGES:
        raise ValueError(t(f"Sprache {language!r} nicht unterstützt, erlaubt: ", f"language {language!r} not supported, allowed: ")
                         + " ".join(LANGUAGES))
    r = mlx_whisper.transcribe(str(wav), path_or_hf_repo=path(), language=language, verbose=None,
                               condition_on_previous_text=False, word_timestamps=True,
                               initial_prompt=_prompt(terms, language))
    words = _words(r)
    segs = [{"start": s["start"], "end": s["end"], "text": _clean(s["text"])} for s in r["segments"]]
    return {"text": " ".join(s["text"] for s in segs), "words": words, "segments": segs}
