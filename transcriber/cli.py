"""Kommandozeile.

  transcriber transcribe DATEI… [--language de|en|es|fr|…] [--speakers N] [--srt] [--out DIR] [--progress json]
  transcriber who TRANSKRIPT [SPRECHER]        wer ist wer (mit Ähnlichkeiten)
  transcriber name TRANSKRIPT SPRECHER NAME   Stimme benennen (Datenbank lernt mit)
  transcriber confirm TRANSKRIPT              automatische Zuordnungen bestätigen
  transcriber speakers [list|check [--json]|rename A B|merge A B|drop REF-ID|forget NAME]
  transcriber enroll AUDIO BENANNTES.md       Stimmreferenzen aus einem benannten Transkript lernen
  transcriber watch [ORDNER]                  Ordner überwachen
  transcriber vocab [EINTRAG…]                Glossar zeigen oder ergänzen, z. B. 'ACME = Akme'
  transcriber rename TRANSKRIPT NEUER-NAME     Aufnahme samt Transkript umbenennen (Verweise werden mitgezogen)
  transcriber dictate-server                  Diktat-Dienst (startet die App; Modell bleibt geladen)
  transcriber dictate AUDIO [--language en]   Testdiktat über den laufenden Dienst
TRANSKRIPT = .transcript.json oder die .md daneben. SPRECHER = Buchstabe (B), Anzeigename oder SPEAKER_01."""
import argparse
import json
import sys
from pathlib import Path

from . import asr, config
from .i18n import status, t

USAGE_EN = """Command line.

  transcriber transcribe FILE… [--language de|en|es|fr|…] [--speakers N] [--srt] [--out DIR] [--progress json]
  transcriber who TRANSCRIPT [SPEAKER]         who is who (with similarities)
  transcriber name TRANSCRIPT SPEAKER NAME    name a voice (the database learns it)
  transcriber confirm TRANSCRIPT              confirm automatic matches
  transcriber speakers [list|check [--json]|rename A B|merge A B|drop REF-ID|forget NAME]
  transcriber enroll AUDIO NAMED.md           learn voice references from a named transcript
  transcriber watch [FOLDER]                  watch a folder
  transcriber vocab [ENTRY…]                  show or extend the glossary, e.g. 'ACME = Akme'
  transcriber rename TRANSCRIPT NEW-NAME      rename recording and transcript (references are updated)
  transcriber dictate-server                  dictation service (started by the app; model stays loaded)
  transcriber dictate AUDIO [--language en]   test dictation via the running service
TRANSCRIPT = .transcript.json or the .md next to it. SPEAKER = letter (B), display name or SPEAKER_01."""


def _progress_printer(mode):
    if mode == "json":
        return lambda st, f, msg: print(json.dumps({"stage": st, "progress": f, "message": msg}, ensure_ascii=False),
                                        file=sys.stderr, flush=True)
    last = {"m": None}

    def p(st, f, msg):
        if msg != last["m"] or st == "done":
            print(f"  {f:4.0%}  {msg}", file=sys.stderr, flush=True); last["m"] = msg
    return p


def cmd_transcribe(a):
    from . import pipeline
    fmts = config.load()["formats"] + (["srt"] if a.srt else [])
    rc = 0
    for f in a.files:
        print(f"→ {f}", file=sys.stderr)
        try:
            doc, paths = pipeline.run(f, out_dir=a.out, formats=fmts, num_speakers=a.speakers,
                                      progress=_progress_printer(a.progress), language=a.language)
        except Exception as e:  # weiter mit der nächsten Datei
            print("  " + t("FEHLER", "ERROR") + f": {e}", file=sys.stderr); rc = 1; continue
        if a.progress == "json":
            print(json.dumps({"result": {k: str(v) for k, v in paths.items()}}), flush=True)
        else:
            print(paths.get("md", paths["json"]))
            for c in sorted(doc["speakers"], key=lambda c: -c["speech_s"]):
                print(f"  {c['letter']}  {c['display']:22s} {c['speech_s'] / 60:5.1f} min  {status(c['status'])}"
                      + (f" ({c['score']:.2f})" if c.get("score") else ""), file=sys.stderr)
    return rc


def cmd_who(a):
    from . import pipeline
    doc, _ = pipeline.load_doc(a.transcript)
    cs = [pipeline.find_cluster(doc, a.speaker)] if a.speaker else doc["speakers"]
    for c in cs:
        cand = ", ".join(f"{n} {s:.2f}" for n, s in c.get("candidates") or []) or t("keine Referenzen", "no references")
        print(f"{c['letter']}  {c['display']:22s} {c['speech_s'] / 60:5.1f} min  {status(c['status']):10s}  "
              + t("Kandidaten", "Candidates") + f": {cand}")


def cmd_name(a):
    from . import pipeline
    paths, stored, c = pipeline.name_speaker(a.transcript, a.speaker, a.name)
    print(f"{c['letter']} = {a.name}" + ("" if stored else t(" (zu wenig Sprechzeit für eine Stimmreferenz, nur im Transkript benannt)",
                                                             " (too little speaking time for a voice reference, named in the transcript only)")))
    print(paths.get("md", paths["json"]))


def cmd_confirm(a):
    from . import pipeline
    done = pipeline.confirm(a.transcript)
    print(t("bestätigt: ", "confirmed: ") + (", ".join(done) or t("nichts (keine automatischen Zuordnungen)", "nothing (no automatic matches)")))


def cmd_speakers(a):
    from . import speakers
    db = speakers.connect()
    if a.action == "list":
        for p in speakers.persons(db):
            print(f"{p['name']:20s} {p['n']:3d} " + t("Referenzen", "references") + f"  {p['s'] / 60:6.1f} min")
    elif a.action == "check" and a.json:
        print(json.dumps(speakers.consistency(db), ensure_ascii=False))
    elif a.action == "check":
        for name, refs in speakers.consistency(db).items():
            print(name)
            for r in refs:
                flag = t("  ← prüfen", "  ← check") if r["sim_to_rest"] is not None and r["sim_to_rest"] < 0.6 else ""
                print(f"   #{r['id']:<4d} {r['sim_to_rest'] if r['sim_to_rest'] is not None else '–':>5}  "
                      f"{(r['speech_s'] or 0) / 60:5.1f} min  {Path(r['source'] or '').name} {r['label']}{flag}")
    elif a.action == "rename":
        speakers.rename(db, *a.args); print(t("umbenannt", "renamed"))
    elif a.action == "merge":
        speakers.merge(db, *a.args); print(t("zusammengeführt", "merged"))
    elif a.action == "drop":
        speakers.drop_ref(db, a.args[0]); print(t(f"Referenz #{a.args[0]} entfernt", f"reference #{a.args[0]} removed"))
    elif a.action == "forget":
        speakers.forget(db, a.args[0]); print(t(f"{a.args[0]} samt Stimmreferenzen entfernt", f"{a.args[0]} removed with all voice references"))


def cmd_enroll(a):
    from . import enroll
    enroll.from_named_transcript(a.audio, a.named, dry=a.dry_run)


def cmd_watch(a):
    from . import watch
    watch.run(a.dir)


def cmd_vocab(a):
    f = Path(config.load()["vocab_file"]).expanduser()
    if a.terms:
        f.parent.mkdir(parents=True, exist_ok=True)
        old = f.read_text().splitlines() if f.exists() else []
        f.write_text("\n".join(dict.fromkeys(old + a.terms)) + "\n")
    print(f.read_text() if f.exists() else t("(leer)", "(empty)") + f" {f}")


def cmd_rename(a):
    from . import pipeline
    paths = pipeline.rename(a.transcript, a.name)
    print(json.dumps({k: str(v) for k, v in paths.items()}, ensure_ascii=False) if a.json else paths["source"])


def cmd_dictate_server(a):
    from . import dictate
    return dictate.serve()


def cmd_dictate(a):
    import tempfile
    from . import audio, dictate
    import soundfile as sf
    with tempfile.TemporaryDirectory() as d:
        wav = Path(d) / "a.wav"
        audio.prepare(a.audio, wav)
        samples, _ = sf.read(wav, dtype="float32")
    res = dictate.request(samples, a.language)
    if "error" in res:
        print(t("Fehler", "Error") + f": {res['error']}", file=sys.stderr); return 1
    print(res["text"])
    print(f"  {res['audio_s']} s " + t("Audio", "audio") + f", {res['ms']} ms", file=sys.stderr)


def main(argv=None):
    ap = argparse.ArgumentParser(prog="transcriber", description=t(__doc__, USAGE_EN), formatter_class=argparse.RawDescriptionHelpFormatter)
    sp = ap.add_subparsers(dest="cmd", required=True)
    p = sp.add_parser("transcribe", help=t("Datei(en) transkribieren", "transcribe file(s)"))
    p.add_argument("files", nargs="+")
    p.add_argument("--language", choices=asr.LANGUAGES, metavar="CODE", help=t("Sprache, z. B. de, en, es, fr (Standard aus config.json, sonst de)", "language, e.g. de, en, es, fr (default from config.json, else de)"))
    p.add_argument("--speakers", type=int, help=t("feste Sprecherzahl (sonst 2–6 automatisch)", "fixed number of speakers (else 2–6 automatically)"))
    p.add_argument("--srt", action="store_true"); p.add_argument("--out", help=t("Ausgabeordner (sonst neben der Datei)", "output folder (else next to the file)"))
    p.add_argument("--progress", choices=["text", "json"], default="text"); p.set_defaults(f=cmd_transcribe)
    p = sp.add_parser("who", help=t("Sprecherzuordnung anzeigen", "show speaker matches")); p.add_argument("transcript"); p.add_argument("speaker", nargs="?"); p.set_defaults(f=cmd_who)
    p = sp.add_parser("name", help=t("Sprecher benennen", "name a speaker")); p.add_argument("transcript"); p.add_argument("speaker"); p.add_argument("name"); p.set_defaults(f=cmd_name)
    p = sp.add_parser("confirm", help=t("Zuordnungen bestätigen", "confirm matches")); p.add_argument("transcript"); p.set_defaults(f=cmd_confirm)
    p = sp.add_parser("speakers", help=t("Sprecherdatenbank", "speaker database")); p.add_argument("action", nargs="?", default="list", choices=["list", "check", "rename", "merge", "drop", "forget"])
    p.add_argument("--json", action="store_true", help=t("check: maschinenlesbar", "check: machine-readable"))
    p.add_argument("args", nargs="*"); p.set_defaults(f=cmd_speakers)
    p = sp.add_parser("enroll", help=t("Stimmen aus benanntem Transkript lernen", "learn voices from a named transcript")); p.add_argument("audio"); p.add_argument("named")
    p.add_argument("--dry-run", action="store_true"); p.set_defaults(f=cmd_enroll)
    p = sp.add_parser("watch", help=t("Ordner überwachen", "watch a folder")); p.add_argument("dir", nargs="?"); p.set_defaults(f=cmd_watch)
    p = sp.add_parser("vocab", help=t("Glossar (Namen/Fachbegriffe, optional mit Ersetzungen)", "glossary (names/terms, optionally with replacements)")); p.add_argument("terms", nargs="*"); p.set_defaults(f=cmd_vocab)
    p = sp.add_parser("rename", help=t("Aufnahme samt Transkript umbenennen", "rename recording and transcript")); p.add_argument("transcript"); p.add_argument("name")
    p.add_argument("--json", action="store_true", help=t("neue Pfade als JSON", "new paths as JSON")); p.set_defaults(f=cmd_rename)
    p = sp.add_parser("dictate-server", help=t("Diktat-Dienst", "dictation service")); p.set_defaults(f=cmd_dictate_server)
    p = sp.add_parser("dictate", help=t("Testdiktat über den Dienst", "test dictation via the service")); p.add_argument("audio")
    p.add_argument("--language", choices=asr.LANGUAGES, metavar="CODE", default="de"); p.set_defaults(f=cmd_dictate)
    a = ap.parse_args(argv)
    try:
        sys.exit(a.f(a) or 0)
    except KeyError as e:
        print(t("Fehler", "Error") + f": {e.args[0]}", file=sys.stderr); sys.exit(2)


if __name__ == "__main__":
    main()
