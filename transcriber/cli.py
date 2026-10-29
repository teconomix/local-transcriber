"""Kommandozeile.

  transcriber transcribe DATEI… [--language de|en|es|fr|…] [--speakers N] [--srt] [--out DIR] [--progress json]
  transcriber who TRANSKRIPT [SPRECHER]        wer ist wer (mit Ähnlichkeiten)
  transcriber name TRANSKRIPT SPRECHER NAME   Stimme benennen (Datenbank lernt mit)
  transcriber confirm TRANSKRIPT              automatische Zuordnungen bestätigen
  transcriber recheck TRANSKRIPT              offene Stimmen neu mit der Datenbank abgleichen (ohne neu zu rechnen)
  transcriber speakers [list|check [--json]|rename A B|merge A B|drop REF-ID|forget NAME]
  transcriber speakers export DATEI [NAME…]   Stimmabdrücke weitergeben (keine Aufnahmen; biometrisch – nur mit Einwilligung)
  transcriber speakers import DATEI [NAME…] [--list] [--skip-existing]
  transcriber enroll AUDIO BENANNTES.md       Stimmreferenzen aus einem benannten Transkript lernen
  transcriber watch [ORDNER]                  Ordner überwachen
  transcriber vocab [EINTRAG…]                Glossar zeigen oder ergänzen, z. B. 'ACME = Akme'
  transcriber vocab --apply TRANSKRIPT…       Glossar auf fertige Transkripte anwenden (ohne neu zu rechnen)
  transcriber rename TRANSKRIPT NEUER-NAME     Aufnahme samt Transkript umbenennen (Verweise werden mitgezogen)
  transcriber summarize TRANSKRIPT [--template ID] [--auto]   Zusammenfassung mit Sprachmodell → <name>.summary.md
  transcriber summarize --templates | --models  Vorlagen bzw. Modelle des eingestellten Servers zeigen
  transcriber ai-server [--start | --stop [--if-idle]]   lokalen KI-Server per Startbefehl starten/beenden, sonst Status
  transcriber dictate-server                  Diktat-Dienst (startet die App; Modell bleibt geladen)
  transcriber dictate AUDIO [--language en]   Testdiktat über den laufenden Dienst
  transcriber report ZIP [--description DATEI] [--keep-names]   Fehlerbericht (ohne Aufnahmen/Transkripte)
  transcriber model [turbo|turbo-8bit] [--download] [--remove NAME] [--json]   Spracherkennungsmodell zeigen, wechseln, löschen
TRANSKRIPT = .transcript.json oder das lesbare daneben (.txt/.md). SPRECHER = Buchstabe (B), Anzeigename oder SPEAKER_01."""
import argparse
import json
import sys
import time
from pathlib import Path

from . import asr, config
from .i18n import status, t

USAGE_EN = """Command line.

  transcriber transcribe FILE… [--language de|en|es|fr|…] [--speakers N] [--srt] [--out DIR] [--progress json]
  transcriber who TRANSCRIPT [SPEAKER]         who is who (with similarities)
  transcriber name TRANSCRIPT SPEAKER NAME    name a voice (the database learns it)
  transcriber confirm TRANSCRIPT              confirm automatic matches
  transcriber recheck TRANSCRIPT              match open voices against the database again (no recomputation)
  transcriber speakers [list|check [--json]|rename A B|merge A B|drop REF-ID|forget NAME]
  transcriber speakers export FILE [NAME…]    share voice prints (no recordings; biometric – only with consent)
  transcriber speakers import FILE [NAME…] [--list] [--skip-existing]
  transcriber enroll AUDIO NAMED.md           learn voice references from a named transcript
  transcriber watch [FOLDER]                  watch a folder
  transcriber vocab [ENTRY…]                  show or extend the glossary, e.g. 'ACME = Akme'
  transcriber vocab --apply TRANSCRIPT…       apply the glossary to finished transcripts (no recomputation)
  transcriber rename TRANSCRIPT NEW-NAME      rename recording and transcript (references are updated)
  transcriber summarize TRANSCRIPT [--template ID] [--auto]   summary by a language model → <name>.summary.md
  transcriber summarize --templates | --models  show templates or the models of the configured server
  transcriber ai-server [--start | --stop [--if-idle]]   start/stop the local AI server via start command, else status
  transcriber dictate-server                  dictation service (started by the app; model stays loaded)
  transcriber dictate AUDIO [--language en]   test dictation via the running service
  transcriber report ZIP [--description FILE] [--keep-names]   bug report (no recordings/transcripts)
  transcriber model [turbo|turbo-8bit] [--download] [--remove NAME] [--json]   show, switch or delete the speech recognition model
TRANSCRIPT = .transcript.json or the readable one next to it (.txt/.md). SPEAKER = letter (B), display name or SPEAKER_01."""


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
                                      progress=_progress_printer(a.progress), language=a.language, fresh=a.fresh)
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


def cmd_recheck(a):
    from . import pipeline
    changed = pipeline.recheck(a.transcript)
    print(t("neu erkannt: ", "newly recognized: ") + (", ".join(f"{c['letter']}={c['display']}" for c in changed)
                                                     or t("keine Änderung", "no change")))


def cmd_report(a):
    from . import report
    desc = Path(a.description).read_text() if a.description else ""
    info = json.loads(Path(a.app_info).read_text()) if a.app_info else None
    files = report.build(a.out, desc, info, redact=not a.keep_names)
    print(json.dumps({"zip": str(Path(a.out).expanduser()), "files": files}, ensure_ascii=False))


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
    elif a.action == "export":
        if not a.args:
            print(t("Aufruf: speakers export DATEI [NAME…]", "usage: speakers export FILE [NAME…]"), file=sys.stderr); return 2
        d = speakers.export_voices(db, a.args[1:])
        f = Path(a.args[0]).expanduser()
        f.write_text(json.dumps(d, ensure_ascii=False, indent=1)); f.chmod(0o600)   # biometrisch: nur für mich lesbar
        print(t(f"{len(d['persons'])} Stimme(n) exportiert: ", f"{len(d['persons'])} voice(s) exported: ")
              + ", ".join(p["name"] for p in d["persons"]))
    elif a.action == "import":
        if not a.args:
            print(t("Aufruf: speakers import DATEI [NAME…]", "usage: speakers import FILE [NAME…]"), file=sys.stderr); return 2
        try:
            d = speakers.read_voices(Path(a.args[0]).expanduser())
        except ValueError as e:
            print(t("Fehler", "Error") + f": {e}", file=sys.stderr); return 1
        if a.list:
            known = {p["name"] for p in speakers.persons(db)}
            print(json.dumps([{"name": p["name"], "speech_s": p.get("speech_s"), "exists": speakers.norm_name(p["name"]) in known}
                              for p in d["persons"]], ensure_ascii=False))
            return
        res = speakers.import_voices(db, d, a.args[1:], skip_existing=a.skip_existing, source=Path(a.args[0]).name)
        for name, how in res:
            print(f"{name}: " + {"neu": t("neu", "new"), "ergänzt": t("ergänzt", "added"), "übersprungen": t("übersprungen", "skipped")}[how])


def cmd_enroll(a):
    from . import enroll
    enroll.from_named_transcript(a.audio, a.named, dry=a.dry_run)


def cmd_watch(a):
    from . import watch
    watch.run(a.dir)


def cmd_vocab(a):
    if a.apply:                          # Ausgabe je Datei: Anzahl Ersetzungen <Tab> Pfad (die App liest die Zahl)
        from . import pipeline
        for p in a.apply:
            print(f"{pipeline.apply_glossary(p)}\t{p}")
        return
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


def cmd_ai_server(a):
    from . import aiserver
    if a.supervise:
        return aiserver.supervise()
    if a.start:
        started = aiserver.ensure(progress=lambda m: print("  " + m, file=sys.stderr, flush=True))
        print(t("gestartet", "started") if started else t("läuft bereits (oder kein Startbefehl)", "already running (or no start command)"))
        return
    if a.stop:
        r = aiserver.stop(if_idle=a.if_idle)
        print({"none": t("kein von Transcriber gestarteter Server", "no server started by Transcriber"),
               "busy": t("wird gerade benutzt – bleibt an", "in use – stays on"),
               "stopping": t("wird beendet", "stopping")}[r])
        return
    st = aiserver.status()
    print(json.dumps(st, ensure_ascii=False) if a.json else "\n".join(f"{k}: {v}" for k, v in st.items()))


def cmd_summarize(a):
    from . import summarize
    if a.templates:
        ts = summarize.templates()
        if a.json:
            print(json.dumps([{k: v for k, v in x.items() if k != "body"} for x in ts.values()], ensure_ascii=False))
        else:
            for x in ts.values():
                print(f"{x['id']:14s} {x['name']}" + (t("  (eigene)", "  (custom)") if x["custom"] else "") + f"\n{'':14s} {x['description']}")
        return
    if a.models:                         # zugleich Verbindungstest für die App
        s = summarize.settings()
        ms = summarize.models(s)
        print(json.dumps({"base_url": s["base_url"], "local": summarize.is_local(s["base_url"]), "models": ms}, ensure_ascii=False)
              if a.json else "\n".join(ms))
        return
    if not a.transcript:
        print(t("Aufruf: summarize TRANSKRIPT [--template ID]", "usage: summarize TRANSCRIPT [--template ID]"), file=sys.stderr); return 2
    cfg = config.load()
    allow_cloud = not a.auto or summarize.settings(cfg)["cloud_auto"]
    out, meta = summarize.run(a.transcript, a.template, cfg, allow_cloud=allow_cloud,
                              progress=None if a.json else lambda m: print("  " + m, file=sys.stderr, flush=True))
    if a.json:
        print(json.dumps({"summary": str(out), **meta, **summarize.preview(out)}, ensure_ascii=False))
    else:
        print(out)
        print(f"  {meta['model']} · {meta['seconds']} s · " + t("Tokens ein/aus", "tokens in/out") + f" {meta['tokens'][0]}/{meta['tokens'][1]}",
              file=sys.stderr)


def cmd_delete(a):
    from . import cleanup
    r = cleanup.delete(a.file, audio_only=a.audio_only)
    if a.json:
        print(json.dumps(r, ensure_ascii=False))
    else:
        for f in r["trashed"]:
            print(t("Papierkorb: ", "Trash: ") + f)
        if r["cache"]:
            print(t("Zwischenspeicher gelöscht", "cache deleted"))
        if not r["audio_only"]:
            print(t(f"Stimmdatenbank: Gespräch entfernt ({r['voices']} Referenzen)",
                    f"voice database: conversation removed ({r['voices']} references)"))


def cmd_cleanup(a):
    from . import cleanup
    r = cleanup.cleanup(audio_days=a.audio_days, dry_run=a.dry_run)
    if a.dry_run and not a.json:
        print("\n".join(r["plan"]) or t("nichts zu tun", "nothing to do"))
        return
    print(json.dumps(r, ensure_ascii=False) if a.json else
          t(f"Aufgeräumt: {r['forgotten']} gelöschte Aufnahmen, {r['cache']} Zwischenspeicher, {len(r['audio_deleted'])} alte Aufnahmen",
            f"Cleaned up: {r['forgotten']} deleted recordings, {r['cache']} caches, {len(r['audio_deleted'])} old recordings"))


def cmd_library(a):
    from . import library
    items = library.entries()
    if a.json:
        print(json.dumps(items, ensure_ascii=False))
        return
    for e in sorted(items, key=lambda e: e["recorded"] or "", reverse=True):
        print(f"{e['recorded'] or '?':16}  {round(e['duration'] / 60):4} min  {e['folder'] or '.':12}  {e['title']}")


def cmd_model(a):
    """Ohne Namen: eingestelltes Modell und was lokal liegt. Mit Namen: (mit --download erst laden, sonst muss es
    schon da sein) bereitstellen und in config.json eintragen – gilt ab dem nächsten Auftrag, auch für den Wächter; der
    Diktat-Dienst lädt es erst beim Neustart (die App startet ihn nach dem Wechsel neu). --remove: anderes Modell löschen."""
    import os
    if a.remove:
        freed = asr.remove(a.remove)
        if not a.json:
            print(t(f"{a.remove} gelöscht ({freed / 1e9:.1f} GB frei)", f"{a.remove} deleted ({freed / 1e9:.1f} GB freed)"))
    if a.name:
        if a.download:
            os.environ["HF_HUB_OFFLINE"] = "0"
        switched = a.update and asr.default_switch() and a.name == asr.DEFAULT
        asr.prepare(a.name, download=a.download)
        cfg = json.loads(config.CONFIG.read_text()) if config.CONFIG.exists() else {}
        cfg["asr_model"] = a.name
        if a.update:                     # Installer: die einmalige Umstellung ist entschieden – spätere Wahl bleibt
            cfg.setdefault("asr_8bit_switch", time.strftime("%Y-%m-%d"))
            if switched:
                cfg["asr_switch_notice"] = True      # App zeigt einmal „auf 8 Bit umgestellt“
        config.DATA.mkdir(parents=True, exist_ok=True)
        tmp = config.CONFIG.with_suffix(".tmp")
        tmp.write_text(json.dumps(cfg, ensure_ascii=False, indent=2, sort_keys=True))
        tmp.replace(config.CONFIG)
    cur = asr.choice()
    items = [{"name": k, "repo": r, "installed": asr.installed(k), "current": k == cur} for k, (r, _) in asr.MODELS.items()]
    if a.json:
        print(json.dumps({"current": cur, "models": items, "default_switch": asr.default_switch()}, ensure_ascii=False))
        return
    for i in items:
        print(f"{'*' if i['current'] else ' '} {i['name']:11} {i['repo']:42} "
              + (t("geladen", "downloaded") if i["installed"] else t("nicht geladen", "not downloaded")))


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
    config.secure_data()
    ap = argparse.ArgumentParser(prog="transcriber", description=t(__doc__, USAGE_EN), formatter_class=argparse.RawDescriptionHelpFormatter)
    sp = ap.add_subparsers(dest="cmd", required=True)
    p = sp.add_parser("transcribe", help=t("Datei(en) transkribieren", "transcribe file(s)"))
    p.add_argument("files", nargs="+")
    p.add_argument("--language", choices=asr.LANGUAGES, metavar="CODE", help=t("Sprache, z. B. de, en, es, fr (Standard aus config.json, sonst de)", "language, e.g. de, en, es, fr (default from config.json, else de)"))
    p.add_argument("--speakers", type=int, help=t("feste Sprecherzahl (sonst 2–15 automatisch)", "fixed number of speakers (else 2–15 automatically)"))
    p.add_argument("--srt", action="store_true"); p.add_argument("--out", help=t("Ausgabeordner (sonst neben der Datei)", "output folder (else next to the file)"))
    p.add_argument("--fresh", action="store_true", help=t("Spracherkennung neu statt aus dem Zwischenspeicher", "redo speech recognition instead of using the cache"))
    p.add_argument("--progress", choices=["text", "json"], default="text"); p.set_defaults(f=cmd_transcribe)
    p = sp.add_parser("who", help=t("Sprecherzuordnung anzeigen", "show speaker matches")); p.add_argument("transcript"); p.add_argument("speaker", nargs="?"); p.set_defaults(f=cmd_who)
    p = sp.add_parser("name", help=t("Sprecher benennen", "name a speaker")); p.add_argument("transcript"); p.add_argument("speaker"); p.add_argument("name"); p.set_defaults(f=cmd_name)
    p = sp.add_parser("confirm", help=t("Zuordnungen bestätigen", "confirm matches")); p.add_argument("transcript"); p.set_defaults(f=cmd_confirm)
    p = sp.add_parser("recheck", help=t("Namen neu zuordnen (offene Stimmen gegen die Datenbank)", "match names again (open voices against the database)")); p.add_argument("transcript"); p.set_defaults(f=cmd_recheck)
    p = sp.add_parser("speakers", help=t("Sprecherdatenbank", "speaker database")); p.add_argument("action", nargs="?", default="list", choices=["list", "check", "rename", "merge", "drop", "forget", "export", "import"])
    p.add_argument("--json", action="store_true", help=t("check: maschinenlesbar", "check: machine-readable"))
    p.add_argument("--list", action="store_true", help=t("import: nur anzeigen, wer in der Datei ist (JSON)", "import: only show who is in the file (JSON)"))
    p.add_argument("--skip-existing", action="store_true", help=t("import: vorhandene Personen nicht ergänzen", "import: do not add to existing persons"))
    p.add_argument("args", nargs="*"); p.set_defaults(f=cmd_speakers)
    p = sp.add_parser("enroll", help=t("Stimmen aus benanntem Transkript lernen", "learn voices from a named transcript")); p.add_argument("audio"); p.add_argument("named")
    p.add_argument("--dry-run", action="store_true"); p.set_defaults(f=cmd_enroll)
    p = sp.add_parser("watch", help=t("Ordner überwachen", "watch a folder")); p.add_argument("dir", nargs="?"); p.set_defaults(f=cmd_watch)
    p = sp.add_parser("vocab", help=t("Glossar (Namen/Fachbegriffe, optional mit Ersetzungen)", "glossary (names/terms, optionally with replacements)")); p.add_argument("terms", nargs="*")
    p.add_argument("--apply", nargs="+", metavar="TRANSKRIPT", help=t("Glossar auf fertige Transkripte anwenden", "apply the glossary to finished transcripts")); p.set_defaults(f=cmd_vocab)
    p = sp.add_parser("rename", help=t("Aufnahme samt Transkript umbenennen", "rename recording and transcript")); p.add_argument("transcript"); p.add_argument("name")
    p.add_argument("--json", action="store_true", help=t("neue Pfade als JSON", "new paths as JSON")); p.set_defaults(f=cmd_rename)
    p = sp.add_parser("summarize", help=t("Zusammenfassung mit Sprachmodell (Einstellungen › KI)", "summary by a language model (Settings › AI)"))
    p.add_argument("transcript", nargs="?"); p.add_argument("--template", metavar="ID", help=t("Vorlage (Standard: auto_template)", "template (default: auto_template)"))
    p.add_argument("--auto", action="store_true", help=t("automatischer Lauf: Cloud nur mit cloud_auto", "automatic run: cloud only with cloud_auto"))
    p.add_argument("--templates", action="store_true", help=t("Vorlagen zeigen", "list templates"))
    p.add_argument("--models", action="store_true", help=t("Modelle des Servers zeigen (Verbindungstest)", "list the server's models (connection test)"))
    p.add_argument("--json", action="store_true"); p.set_defaults(f=cmd_summarize)
    p = sp.add_parser("ai-server", help=t("lokalen KI-Server (Startbefehl) starten/beenden/zeigen", "start/stop/show the local AI server (start command)"))
    p.add_argument("--start", action="store_true"); p.add_argument("--stop", action="store_true")
    p.add_argument("--if-idle", action="store_true", help=t("mit --stop: nicht, solange er benutzt wird", "with --stop: not while in use"))
    p.add_argument("--supervise", action="store_true", help=argparse.SUPPRESS)
    p.add_argument("--json", action="store_true"); p.set_defaults(f=cmd_ai_server)
    p = sp.add_parser("report", help=t("Fehlerbericht als ZIP (ohne Aufnahmen/Transkripte)", "bug report as ZIP (no recordings/transcripts)"))
    p.add_argument("out"); p.add_argument("--description", metavar=t("DATEI", "FILE")); p.add_argument("--app-info", metavar=t("DATEI", "FILE"))
    p.add_argument("--keep-names", action="store_true", help=t("Dateinamen/Termintitel nicht unkenntlich machen", "do not redact file names/event titles"))
    p.set_defaults(f=cmd_report)
    p = sp.add_parser("delete", help=t("Aufnahme löschen (Dateien in den Papierkorb, Zwischendaten und Stimmen endgültig)",
                                       "delete a recording (files to Trash, cached data and voices permanently)"))
    p.add_argument("file"); p.add_argument("--audio-only", action="store_true",
                                           help=t("nur das Audio, Transkript und Stimmen bleiben", "audio only, keep transcript and voices"))
    p.add_argument("--json", action="store_true"); p.set_defaults(f=cmd_delete)
    p = sp.add_parser("cleanup", help=t("nach Löschen im Finder aufräumen", "clean up after deleting in Finder"))
    p.add_argument("--audio-days", type=int, metavar="N", help=t("Audio/Video in ~/Transcriber N Tage nach dem Transkript löschen (Transkript bleibt)",
                                                                  "delete audio/video in ~/Transcriber N days after transcription (transcript stays)"))
    p.add_argument("--dry-run", action="store_true", help=t("nur anzeigen", "only show"))
    p.add_argument("--json", action="store_true"); p.set_defaults(f=cmd_cleanup)
    p = sp.add_parser("library", help=t("alle Transkripte unter ~/Transcriber (mit Aufnahmedatum)", "all transcripts under ~/Transcriber (with recording date)"))
    p.add_argument("--json", action="store_true"); p.set_defaults(f=cmd_library)
    p = sp.add_parser("model", help=t("Spracherkennungsmodell zeigen oder wechseln", "show or switch the speech recognition model"))
    p.add_argument("name", nargs="?", choices=list(asr.MODELS)); p.add_argument("--download", action="store_true", help=t("vorher laden (Netz)", "download first (network)"))
    p.add_argument("--remove", choices=list(asr.MODELS), metavar="NAME", help=t("nicht genutztes Modell löschen", "delete an unused model"))
    p.add_argument("--update", action="store_true", help=t("vom Installer: einmalige Umstellung auf 8 Bit vermerken", "from the installer: record the one-time switch to 8-bit"))
    p.add_argument("--json", action="store_true"); p.set_defaults(f=cmd_model)
    p = sp.add_parser("dictate-server", help=t("Diktat-Dienst", "dictation service")); p.set_defaults(f=cmd_dictate_server)
    p = sp.add_parser("dictate", help=t("Testdiktat über den Dienst", "test dictation via the service")); p.add_argument("audio")
    p.add_argument("--language", choices=asr.LANGUAGES, metavar="CODE", default="de"); p.set_defaults(f=cmd_dictate)
    a = ap.parse_args(argv)
    try:
        sys.exit(a.f(a) or 0)
    except KeyError as e:
        print(t("Fehler", "Error") + f": {e.args[0]}", file=sys.stderr); sys.exit(2)
    except (RuntimeError, FileNotFoundError) as e:          # z. B. delete/rename: Transkription läuft noch
        print(t("Fehler", "Error") + f": {e}", file=sys.stderr); sys.exit(2)


if __name__ == "__main__":
    main()
