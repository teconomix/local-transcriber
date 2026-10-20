"""Spracherkennung mit Whisper large-v3-turbo (mlx-community/whisper-large-v3-turbo, FP16, aus dem HF-Cache).

Modellwahl 2026-10-09 nach Vergleich mit gehörter Referenz (bench/ERGEBNIS.md): turbo vor Parakeet und Qwen3-ASR;
large-v3 entfernt (2,5× langsamer, ungenauere Wortzeiten). Rückgabe: {"text", "words": [{w, start, end, p}], "segments"}."""
REPO = "mlx-community/whisper-large-v3-turbo"
MODEL = "whisper-turbo"
# Alle Sprachcodes, die Whisper kennt (mlx_whisper.tokenizer.LANGUAGES); welche die App anbietet, stellt man dort ein.
LANGUAGES = ("en zh de es ru ko fr ja pt tr pl ca nl ar sv it id hi fi vi he uk el ms cs ro da hu ta no th ur hr bg lt "
             "la mi ml cy sk te fa lv bn sr az sl kn et mk br eu is hy ne mn bs kk sq sw gl mr pa si km sn yo so af "
             "oc ka be tg sd gu am yi lo uz fo ht ps tk nn mt sa lb my bo tl mg as tt haw ln ha ba jw su yue").split()


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
    model = ModelHolder.get_model(REPO, mx.float16)     # derselbe Zwischenspeicher wie mlx_whisper.transcribe
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


def transcribe(wav, terms=None, language="de"):
    """terms: Glossarbegriffe als Prompt – nur wenn config „glossary_prompt“ an ist. Gemessen 2026-10-09: Prompt im
    ersten Fenster WER 9,9 → 10,8 %, in jedem Fenster 15,5 % plus ausgelassene Halbsätze. Deshalb Standard aus;
    das Glossar wirkt über feste Ersetzungen (glossary.apply)."""
    import mlx_whisper
    from .i18n import t
    if language not in LANGUAGES:
        raise ValueError(t(f"Sprache {language!r} nicht unterstützt, erlaubt: ", f"language {language!r} not supported, allowed: ")
                         + " ".join(LANGUAGES))
    r = mlx_whisper.transcribe(str(wav), path_or_hf_repo=REPO, language=language, verbose=None,
                               condition_on_previous_text=False, word_timestamps=True,
                               initial_prompt=_prompt(terms, language))
    # „\ufffd“: Whisper teilt manche Zeichen auf mehrere Token, am Ende bleibt ein halbes UTF-8-Zeichen übrig
    # (2026-10-20: ein Name mit „��“ am Ende) → entfernen.
    clean = lambda x: x.replace("\ufffd", "").strip()
    words = [{"w": clean(w["word"]), "start": w["start"], "end": w["end"], "p": w.get("probability")}
             for s in r["segments"] for w in s.get("words", []) if clean(w["word"])]
    segs = [{"start": s["start"], "end": s["end"], "text": clean(s["text"])} for s in r["segments"]]
    return {"text": " ".join(s["text"] for s in segs), "words": words, "segments": segs}
