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
    words = [{"w": w["word"].strip(), "start": w["start"], "end": w["end"], "p": w.get("probability")}
             for s in r["segments"] for w in s.get("words", []) if w["word"].strip()]
    segs = [{"start": s["start"], "end": s["end"], "text": s["text"].strip()} for s in r["segments"]]
    return {"text": " ".join(s["text"] for s in segs), "words": words, "segments": segs}
