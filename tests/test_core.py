"""Schnelle Tests des Python-Kerns – ohne Modelle, ohne Netz, ohne echte Daten (`scripts/check.sh`).

Alles läuft in einem frischen TRANSCRIBER_DATA-Verzeichnis; die echte Stimmdatenbank wird nie berührt.
Sollergebnisse der Markdown-Ausgabe: tests/fixtures/beispiel.{de,en}.md. Ändert sich die Ausgabe absichtlich:
`UPDATE_GOLDEN=1 scripts/check.sh`, dann die Unterschiede im Diff prüfen."""
import json
import os
import shutil
import sys
import tempfile
import time
import unicodedata
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FIX = ROOT / "tests" / "fixtures"
_DATA = tempfile.mkdtemp(prefix="transcriber-test-")
os.environ["TRANSCRIBER_DATA"] = _DATA            # vor dem Import: config liest es beim Laden
os.environ["TRANSCRIBER_UI_LANG"] = "de"
sys.path.insert(0, str(ROOT))

import numpy as np                                  # noqa: E402

from transcriber import config, glossary, i18n, pipeline, render, speakers   # noqa: E402

STATUS_CODES = {"sicher", "vermutlich", "unbekannt", "bestätigt"}


def set_lang(lang):
    os.environ["TRANSCRIBER_UI_LANG"] = lang
    i18n.lang.cache_clear()


def fresh_db():
    if config.DB.exists():
        config.DB.unlink()
    return speakers.connect()


def sample():
    return json.loads((FIX / "beispiel.transcript.json").read_text())


def tearDownModule():
    shutil.rmtree(_DATA, ignore_errors=True)


class Isolation(unittest.TestCase):
    def test_data_dir_is_temporary(self):
        self.assertEqual(config.DATA, Path(_DATA))
        self.assertNotIn(".local/share/transcriber", str(config.DB))


class Render(unittest.TestCase):
    """Transkript-Ausgabe in beiden Sprachen gegen die Sollergebnisse."""

    def golden(self, lang):
        set_lang(lang)
        doc = sample()
        pipeline.display_names(doc["speakers"], doc["words"])   # wie name/confirm/rename: Anzeige in der Sprache
        md = render.markdown(doc, "beispiel.transcript.json")
        f = FIX / f"beispiel.{lang}.md"
        if os.environ.get("UPDATE_GOLDEN"):
            f.write_text(md)
        self.assertEqual(md, f.read_text(), f"Markdown ({lang}) weicht ab – Absicht? Dann UPDATE_GOLDEN=1")

    def test_markdown_de(self):
        self.golden("de")

    def test_markdown_en(self):
        self.golden("en")

    def test_language_detected_line(self):
        """Sprache automatisch umgestellt → Kopfzeile nennt erkannte und eingestellte Sprache; sonst keine Angabe."""
        set_lang("de")
        doc = sample()
        doc["language"], doc["language_set"] = "de", "en"
        self.assertIn("Sprache: de (erkannt, eingestellt war en)", render.markdown(doc, "x.transcript.json", plain=True))
        doc["language_set"] = None
        self.assertNotIn("Sprache:", render.markdown(doc, "x.transcript.json", plain=True))

    def test_srt_speaker_labels(self):
        set_lang("en")
        doc = sample()
        pipeline.display_names(doc["speakers"], doc["words"])
        s = render.srt(doc)
        self.assertIn("Speaker C", s)
        self.assertNotIn("Sprecher", s)


class Turns(unittest.TestCase):
    """Gleichzeitiges Sprechen (doc["overlaps"]) je Sprecher zusammenfassen, schnellen Dialog nicht."""

    def doc(self, overlaps):
        words, t = [], 10.0
        for i, w in enumerate("eins one zwei two drei three".split()):  # A und B abwechselnd, Wort für Wort
            words.append({"w": w, "start": t, "end": t + 0.3, "speaker": "SPEAKER_00" if i % 2 == 0 else "SPEAKER_01"})
            t += 0.4
        return {"speakers": [{"label": "SPEAKER_00", "display": "A"}, {"label": "SPEAKER_01", "display": "B"}],
                "words": words, "overlaps": overlaps}

    def test_overlap_grouped_per_speaker(self):
        turns = render._turns(self.doc([[9.8, 12.5]]))
        self.assertEqual([(u["who"], u["text"]) for u in turns], [("A", "eins zwei drei"), ("B", "one two three")])

    def test_dialog_without_overlap_stays_interleaved(self):
        self.assertEqual(len(render._turns(self.doc([]))), 6)


class StatusCodes(unittest.TestCase):
    """Gespeicherte Statuswerte bleiben deutsch – die App vergleicht darauf (needsName, „übernehmen“)."""

    def test_display_names_keep_codes(self):
        for lang in ("de", "en"):
            set_lang(lang)
            doc = sample()
            pipeline.display_names(doc["speakers"], doc["words"])
            self.assertEqual({c["status"] for c in doc["speakers"]}, {"bestätigt", "vermutlich", "unbekannt"})
            self.assertEqual([c["display"] for c in doc["speakers"]],
                             ["Alex Muster", "Kim Beispiel (?)", ("Sprecher" if lang == "de" else "Speaker") + " C"])

    def test_old_and_new_display_names_resolve(self):
        doc = sample()
        for who in ("Sprecher C", "Speaker C", "c", "SPEAKER_02"):
            self.assertEqual(pipeline.find_cluster(doc, who)["label"], "SPEAKER_02", who)
        self.assertEqual(pipeline.find_cluster(doc, "Kim Beispiel")["label"], "SPEAKER_01")

    def test_confirm_and_name_store_codes(self):
        set_lang("en")
        tmp = Path(tempfile.mkdtemp(dir=_DATA))
        jp = tmp / "beispiel.transcript.json"
        doc = sample()
        doc["source"] = str(tmp / "beispiel.m4a")
        jp.write_text(json.dumps(doc, ensure_ascii=False))
        db = fresh_db()
        rng = np.random.default_rng(1)
        speakers.save_job(db, doc["job_id"], doc["source"], jp, doc["model"],
                          [{"label": c["label"], "speech_s": c["speech_s"], "embedding": rng.normal(size=192),
                            "status": c["status"]} for c in doc["speakers"]])
        self.assertEqual(pipeline.confirm(jp), ["Kim Beispiel"])
        pipeline.name_speaker(jp, "Speaker C", "Sam Probe")
        out = json.loads(jp.read_text())
        self.assertTrue({c["status"] for c in out["speakers"]} <= STATUS_CODES)
        self.assertEqual({c["display"] for c in out["speakers"]}, {"Alex Muster", "Kim Beispiel", "Sam Probe"})
        # Referenzen nur ab min_enroll_s (15 s): Kim (31 s) ja, Sam (8 s) nicht – die Person entsteht trotzdem
        refs = {r["name"]: r["n"] for r in speakers.persons(db)}
        self.assertEqual(refs, {"Kim Beispiel": 1, "Sam Probe": 0})
        self.assertTrue((tmp / "beispiel.txt").exists())   # Standard seit 0.8: Text

    def test_recheck_matches_open_voices_against_newer_references(self):
        """Neu erkennen: eine seither (in einer anderen Aufnahme) benannte Stimme wird erkannt, Bestätigte bleiben."""
        set_lang("de")
        tmp = Path(tempfile.mkdtemp(dir=_DATA))
        jp = tmp / "beispiel.transcript.json"
        doc = sample()
        doc["source"] = str(tmp / "beispiel.m4a")
        jp.write_text(json.dumps(doc, ensure_ascii=False))
        db = fresh_db()
        rng = np.random.default_rng(3)
        vecs = {c["label"]: rng.normal(size=192) for c in doc["speakers"]}
        speakers.save_job(db, doc["job_id"], doc["source"], jp, doc["model"],
                          [{"label": c["label"], "speech_s": c["speech_s"], "embedding": vecs[c["label"]],
                            "status": c["status"]} for c in doc["speakers"]])
        pid = speakers.person_id(db, "Kim Beispiel")             # in einer späteren Aufnahme benannt
        db.execute("INSERT INTO embeddings(person_id, vec, speech_s, job_id, label) VALUES(?,?,?,?,?)",
                   (pid, speakers._unit(vecs["SPEAKER_01"] + rng.normal(size=192) * 0.1).tobytes(), 120, "anders", "SPEAKER_00"))
        db.commit()
        changed = pipeline.recheck(jp)
        self.assertEqual([c["letter"] for c in changed], ["B"])
        out = {c["letter"]: (c["display"], c["status"]) for c in json.loads(jp.read_text())["speakers"]}
        self.assertEqual(out, {"A": ("Alex Muster", "bestätigt"), "B": ("Kim Beispiel", "sicher"), "C": ("Sprecher C", "unbekannt")})


class Report(unittest.TestCase):
    def test_redactor_whole_words_stable_placeholders(self):
        from transcriber import report
        r = report.Redactor()
        r.add("Kim Beispiel", "Person"); r.add("Kurz", "Name"); r.add("Budget Q4, Tag 1", "Termin"); r.add("Budget Q4", "Termin")
        out = r("Kim Beispiel im Termin Budget Q4, Tag 1 und Budget Q4; Kurzfassung bleibt, Kurz nicht; mail kim@example.org")
        self.assertEqual(out, "‹Person 1› im Termin ‹Termin 1› und ‹Termin 2›; Kurzfassung bleibt, ‹Name 1› nicht; mail ‹E-Mail›")
        self.assertEqual(report.Redactor(enabled=False)("Kim Beispiel"), "Kim Beispiel")

    def test_report_redacts_deleted_and_outside_files(self):
        """Gelöschte Aufnahmen (nur noch im Protokoll) und Aufträge außerhalb des Wächterordners werden geschwärzt."""
        import zipfile
        from transcriber import report
        tmp = Path(tempfile.mkdtemp(dir=_DATA))
        (tmp / "Transcriber").mkdir()
        config.CONFIG.write_text(json.dumps({"watch_dir": str(tmp / "Transcriber")}))
        (config.DATA / "app.log").write_text("2026-10-20T21:00:00Z Aufnahme samt Transkript gelöscht: 2026-10-14 Geheimes Projekt.m4a\n")
        (config.DATA / "watch.log").write_text("22:55:54 ↪ Alt verschoben.m4a: umbenannt, Transkript nachgezogen\n"
                                               "   FEHLER, siehe Kaputt geheim.error.txt\n")
        config.JOBS.mkdir(parents=True, exist_ok=True)
        (config.JOBS / "extern.json").write_text(json.dumps({"source": "/anderswo/Vertrauliche Runde.m4a", "state": "done"}))
        try:
            out = tmp / "bericht.zip"
            report.build(out, "x")
            with zipfile.ZipFile(out) as z:
                text = "\n".join(z.read(n).decode() for n in z.namelist())
            for secret in ("Geheimes Projekt", "Alt verschoben", "Kaputt geheim", "Vertrauliche Runde"):
                self.assertNotIn(secret, text)
            self.assertIn("gelöscht: ‹Datei", text)
        finally:
            config.CONFIG.unlink(missing_ok=True)
            for n in ("app.log", "watch.log"):
                (config.DATA / n).unlink(missing_ok=True)
            (config.JOBS / "extern.json").unlink(missing_ok=True)

    def test_report_redacts_folders_speakers_and_english_log(self):
        import zipfile
        from transcriber import report
        tmp = Path(tempfile.mkdtemp(dir=_DATA))
        kunde = tmp / "Transcriber" / "Kunde Quast" / "2026"
        kunde.mkdir(parents=True)
        doc = {"speakers": [{"name": "Wiebke von Sandau"}], "event": {"title": "Klausur Nordlicht", "attendees": [{"name": "Ole Brix"}]}}
        (kunde / "a.transcript.json").write_text(json.dumps(doc))
        config.CONFIG.write_text(json.dumps({"watch_dir": str(tmp / "Transcriber")}))
        (config.DATA / "watch.log").write_text("watching /Volumes/Geheimplatte/Mandanten\n"
                                               "   done: Erstgespräch Zander.txt  Wiebke von Sandau\n"
                                               "2026-10-28 Kunde Quast/2026 Sandau Brix Klausur Nordlicht von der Aufnahmen\n")
        try:
            out = tmp / "bericht.zip"
            report.build(out, "x")
            with zipfile.ZipFile(out) as z:
                log = z.read("protokolle/watch.log").decode()
            for secret in ("Quast", "Wiebke", "Sandau", "Brix", "Nordlicht", "Zander", "Geheimplatte", "Mandanten"):
                self.assertNotIn(secret, log)
            self.assertIn("2026-10-28 ‹Ordner", log)                 # Zeitstempel bleiben lesbar
            self.assertIn(" von der Aufnahmen", log)                  # Artikel/Präpositionen und App-Ordner bleiben
        finally:
            config.CONFIG.unlink(missing_ok=True)
            (config.DATA / "watch.log").unlink(missing_ok=True)

    def test_report_zip_has_no_recordings_and_redacts_titles(self):
        import zipfile
        from transcriber import report
        tmp = Path(tempfile.mkdtemp(dir=_DATA))
        watch = tmp / "Transcriber" / "Aufnahmen"
        watch.mkdir(parents=True)
        (watch / "2026-10-14 Geheimes Projekt.m4a").write_bytes(b"\0" * 64)
        (watch / "2026-10-14 Geheimes Projekt.transcript.json").write_text("{}")
        config.CONFIG.write_text(json.dumps({"watch_dir": str(tmp / "Transcriber")}))
        (config.DATA / "app.log").write_text("2026-10-14T10:00:00Z Aufnahme benannt in 0.1 s: 2026-10-14 Geheimes Projekt.m4a\n"
                                             "2026-10-14T10:00:01Z Termin zur Aufnahme: Vertrauliche Runde (3 Teilnehmer)\n")
        try:
            out = tmp / "bericht.zip"
            files = report.build(out, "Mikro geht nicht")
            with zipfile.ZipFile(out) as z:
                text = "\n".join(z.read(n).decode() for n in z.namelist())
            self.assertIn("protokolle/app.log", files)
            self.assertFalse([n for n in files if n.endswith((".m4a", ".transcript.json", ".db"))])
            self.assertNotIn("Geheimes Projekt", text)
            self.assertNotIn("Vertrauliche Runde", text)
            self.assertIn("Mikro geht nicht", text)
            self.assertIn("speicher.json", files)
            with zipfile.ZipFile(out) as z:
                mem = json.loads(z.read("speicher.json"))
            self.assertIn("transcriber", mem)                    # auf jedem Mac vorhanden, auch ohne laufende Prozesse
            self.assertNotIn(str(tmp), json.dumps(mem))
        finally:
            config.CONFIG.unlink(missing_ok=True)
            (config.DATA / "app.log").unlink(missing_ok=True)


class Rename(unittest.TestCase):
    """Umbenennen zieht Audio, Begleitdateien, Stimmdatenbank und App-Statusdateien mit."""

    def test_rename_everything(self):
        set_lang("de")
        tmp = Path(tempfile.mkdtemp(dir=_DATA))
        old = "Aufnahme 2026-10-10 14-03"
        audio = tmp / f"{old}.m4a"
        audio.write_bytes(b"\0" * 16)
        doc = sample()
        doc["source"] = str(audio)
        jp = tmp / f"{old}.transcript.json"
        jp.write_text(json.dumps(doc, ensure_ascii=False))
        (tmp / f"{old}.md").write_text(render.markdown(doc, jp.name))     # eigenes Transkript (Kopf „Quelle: …“)
        (tmp / f"{old}.srt").write_text("alt")
        (tmp / f"{old}.event.json").write_text(json.dumps(doc["event"]))
        db = fresh_db()
        db.execute("INSERT INTO jobs VALUES(?,?,?,?,?)", (doc["job_id"], str(audio), str(jp), "m", 0))
        pid = speakers.person_id(db, "Alex Muster")
        db.execute("INSERT INTO embeddings(person_id, vec, speech_s, job_id, label, source) VALUES(?,?,?,?,?,?)",
                   (pid, np.zeros(4, np.float32).tobytes(), 72, doc["job_id"], "SPEAKER_00", str(audio)))
        db.commit()
        config.JOBS.mkdir(parents=True, exist_ok=True)
        status = config.JOBS / "test-status.json"
        status.write_text(json.dumps({"source": str(audio), "state": "done", "result": {"json": str(jp)}}))

        paths = pipeline.rename(jp, "2026-10-10 14-03 Budget: Q4/Plan")   # Sonderzeichen werden entfernt
        new = "2026-10-10 14-03 Budget Q4 Plan"
        self.assertEqual(Path(paths["source"]).name, f"{new}.m4a")
        self.assertEqual(sorted(p.name for p in tmp.iterdir()),
                         sorted(f"{new}{e}" for e in (".m4a", ".transcript.json", ".md", ".srt", ".event.json")))
        self.assertEqual(json.loads((tmp / f"{new}.transcript.json").read_text())["source"], str(tmp / f"{new}.m4a"))
        self.assertEqual(db.execute("SELECT source FROM jobs").fetchone()[0], str(tmp / f"{new}.m4a"))
        self.assertEqual(db.execute("SELECT source FROM embeddings").fetchone()[0], str(tmp / f"{new}.m4a"))
        st = json.loads(status.read_text())
        self.assertEqual(st["source"], str(tmp / f"{new}.m4a"))
        self.assertEqual(Path(st["result"]["json"]).name, f"{new}.transcript.json")
        status.unlink()

    def test_finder_rename_or_move_adopts_transcript(self):
        """Im Finder umbenannt/verschoben: Transkript samt Begleitdateien wandert mit, statt neu transkribiert zu werden.
        Eine Kopie (Original liegt noch) wird dagegen nicht übernommen."""
        set_lang("de")
        tmp = Path(tempfile.mkdtemp(dir=_DATA)).resolve()
        audio = tmp / "Aufnahmen" / "alt.m4a"
        audio.parent.mkdir()
        audio.write_bytes(b"\1" * 32)
        doc = sample()
        doc["source"], doc["job_id"] = str(audio), pipeline.job_id(audio)
        jp = audio.with_name("alt.transcript.json")
        jp.write_text(json.dumps(doc, ensure_ascii=False))
        audio.with_name("alt.md").write_text(render.markdown(doc, jp.name))
        audio.with_name("alt.event.json").write_text("alt")
        db = fresh_db()
        db.execute("INSERT INTO jobs VALUES(?,?,?,?,?)", (doc["job_id"], str(audio), str(jp), "m", 0))
        db.commit()

        copy = tmp / "kopie.m4a"
        copy.write_bytes(audio.read_bytes())
        self.assertIsNone(pipeline.find_moved(copy))                 # Original noch da: Kopie, nicht umbenannt
        copy.unlink()

        moved = tmp / "Projekt" / "Neuer Titel.m4a"
        moved.parent.mkdir()
        audio.rename(moved)
        doc2, paths = pipeline.run(moved)                             # ohne Modelle: nur nachziehen
        self.assertEqual(sorted(p.name for p in moved.parent.iterdir()),
                         ["Neuer Titel.event.json", "Neuer Titel.m4a", "Neuer Titel.md", "Neuer Titel.transcript.json"])
        self.assertEqual(list(audio.parent.iterdir()), [])
        self.assertEqual(doc2["source"], str(moved))
        self.assertEqual(tuple(db.execute("SELECT source, transcript FROM jobs").fetchone()),
                         (str(moved), str(moved.with_name("Neuer Titel.transcript.json"))))

    def test_running_transcription_blocks_rename(self):
        tmp = Path(tempfile.mkdtemp(dir=_DATA))
        doc = sample()
        doc["source"] = str(tmp / "x.m4a")
        (tmp / "x.m4a").write_bytes(b"\0")
        (tmp / "x.lock").write_text("")
        jp = tmp / "x.transcript.json"
        jp.write_text(json.dumps(doc))
        with self.assertRaises(RuntimeError):
            pipeline.rename(jp, "y")


class Delete(unittest.TestCase):
    """Löschen (ganz / nur Audio) und Aufräumen nach Löschen im Finder bzw. nach N Tagen."""

    def setUp(self):
        set_lang("de")
        self.tmp = Path(tempfile.mkdtemp(dir=_DATA))
        self.trash = self.tmp / "Papierkorb"
        os.environ["TRANSCRIBER_TRASH"] = str(self.trash)       # nie in den echten Papierkorb
        self.rec = self.tmp / "Transcriber" / "Aufnahmen"
        self.rec.mkdir(parents=True)
        config.CONFIG.write_text(json.dumps({"watch_dir": str(self.tmp / "Transcriber")}))
        self.db = fresh_db()
        config.JOBS.mkdir(parents=True, exist_ok=True)
        for f in config.JOBS.glob("*.json"):
            f.unlink()

    def tearDown(self):
        os.environ.pop("TRANSCRIBER_TRASH", None)

    def make(self, name, jid, named=True, folder=None, ext=".m4a", days=0):
        from transcriber import cleanup                          # noqa: F401  (Import prüfen)
        d = folder or self.rec
        d.mkdir(parents=True, exist_ok=True)
        audio = d / f"{name}{ext}"
        audio.write_bytes(name.encode() * 4)
        jid = jid or pipeline.job_id(audio)                      # None: echte job_id (Inhalts-Hash)
        doc = sample()
        doc["source"], doc["job_id"] = str(audio), jid
        doc["created"] = time.strftime("%Y-%m-%d %H:%M", time.localtime(time.time() - days * 86400))
        jp = d / f"{name}.transcript.json"
        jp.write_text(json.dumps(doc, ensure_ascii=False))
        (d / f"{name}.txt").write_text(render.markdown(doc, jp.name, plain=True))
        (d / f"{name}.event.json").write_text("{}")
        (config.CACHE / jid).mkdir(parents=True, exist_ok=True)
        (config.CACHE / jid / "audio.wav").write_bytes(b"\0")
        v = np.ones(4, np.float32).tobytes()
        self.db.execute("INSERT INTO jobs VALUES(?,?,?,?,?)", (jid, str(audio), str(jp), "m", 0))
        self.db.execute("INSERT INTO clusters VALUES(?,?,?,?,?,?,?)", (jid, "SPEAKER_00", v, 70, None, None, None))
        if named:
            pid = speakers.person_id(self.db, f"Person {jid}")
            self.db.execute("INSERT INTO embeddings(person_id, vec, speech_s, job_id, label, source) VALUES(?,?,?,?,?,?)",
                            (pid, v, 70, jid, "SPEAKER_00", str(audio)))
        self.db.commit()
        (config.JOBS / f"{jid}.json").write_text(json.dumps({"source": str(audio), "state": "done"}))
        return audio, jp

    def count(self, table, jid):
        return self.db.execute(f"SELECT count(*) FROM {table} WHERE {'id' if table == 'jobs' else 'job_id'}=?", (jid,)).fetchone()[0]

    def test_delete_all_and_audio_only(self):
        from transcriber import cleanup
        audio, jp = self.make("Gespräch A", "aaa1")
        (self.rec / "Gespräch A.md").write_text("eigene Notiz, nicht von Transcriber")   # fremde Datei gleichen Namens
        r = cleanup.delete(audio)
        self.assertEqual(sorted(p.name for p in self.rec.iterdir()), ["Gespräch A.md"])   # fremde bleibt
        self.assertEqual(len(list(self.trash.iterdir())), 4)                              # Audio, json, txt, event
        self.assertFalse((config.CACHE / "aaa1").exists())
        self.assertEqual((r["voices"], self.count("jobs", "aaa1"), self.count("clusters", "aaa1")), (1, 0, 0))
        self.assertIsNone(self.db.execute("SELECT id FROM persons WHERE name='Person aaa1'").fetchone())
        # Person nur mit kurzer Sprechzeit (keine Referenz, nur bestätigter Sprecher einer anderen Aufnahme) bleibt
        pid = speakers.person_id(self.db, "Kurz Sprechende")
        self.db.execute("INSERT INTO clusters VALUES(?,?,?,?,?,?,?)", ("zzz0", "SPEAKER_01", np.ones(4, np.float32).tobytes(), 9, pid, 1.0, "bestätigt"))
        self.db.commit()
        self.assertFalse((config.JOBS / "aaa1.json").exists())

        audio, jp = self.make("Gespräch B", "bbb2")
        a3, j3 = self.make("Gespräch C", "ccc0", named=False)
        cleanup.delete(a3)
        self.assertIsNotNone(self.db.execute("SELECT id FROM persons WHERE name='Kurz Sprechende'").fetchone())
        cleanup.delete(jp, audio_only=True)
        self.assertFalse(audio.exists())
        self.assertTrue(jp.exists() and (self.rec / "Gespräch B.txt").exists())
        self.assertFalse((config.CACHE / "bbb2").exists())
        self.assertEqual((self.count("embeddings", "bbb2"), self.count("clusters", "bbb2")), (1, 1))   # Stimmen bleiben
        self.assertTrue((config.JOBS / "bbb2.json").exists())                                          # Eintrag bleibt

    def test_running_transcription_is_not_deleted(self):
        from transcriber import cleanup
        audio, jp = self.make("Läuft", "ccc3")
        (self.rec / "Läuft.lock").write_text("1")
        with self.assertRaises(RuntimeError):
            cleanup.delete(audio)
        self.assertTrue(audio.exists())

    def test_delete_failed_job_takes_sidecars_and_stale_lock(self):
        """„Alles löschen“ ohne Transkript (Auftrag fehlgeschlagen): Begleitdateien, Lock-Rest und Status gehen mit."""
        import subprocess
        from transcriber import cleanup
        audio = self.rec / "Kaputt.m4a"
        audio.write_bytes(b"kaputt")
        (self.rec / "Kaputt.error.txt").write_text("Traceback")
        (self.rec / "Kaputt.event.json").write_text("{}")
        dead = subprocess.Popen(["/usr/bin/true"]); dead.wait()
        (self.rec / "Kaputt.lock").write_text(str(dead.pid))       # Rest eines abgebrochenen Laufs
        (config.JOBS / "kaputt.json").write_text(json.dumps({"source": str(audio), "state": "failed"}))
        r = cleanup.delete(audio)
        self.assertEqual(list(self.rec.iterdir()), [])
        self.assertEqual(len(r["trashed"]), 3)
        self.assertFalse((config.JOBS / "kaputt.json").exists())

    def test_cleanup_orphan_caches_and_missing_subfolder(self):
        """Verwaiste Zwischenspeicher (> 1 Tag, nur ohne laufende Transkription); fehlender Unterordner in watch_dir."""
        import fcntl
        from transcriber import cleanup
        sub = self.rec.parent / "Projekt"
        a, j = self.make("Im Unterordner", "sub1", folder=sub)
        shutil.rmtree(sub)                                           # ganzer Unterordner im Finder gelöscht
        old, fresh = config.CACHE / "verwaist1", config.CACHE / "frisch1"
        for d in (old, fresh):
            d.mkdir(parents=True, exist_ok=True)
            (d / "audio.wav").write_bytes(b"\0")
        t2 = time.time() - 2 * 86400
        for f in (old / "audio.wav", old):
            os.utime(f, (t2, t2))
        with open(config.DATA / "run.lock", "a") as lk:               # Transkription läuft: nichts Verwaistes anfassen
            fcntl.flock(lk, fcntl.LOCK_EX)
            cleanup.cleanup()
        self.assertTrue(old.exists())
        r = cleanup.cleanup()
        self.assertFalse(old.exists())
        self.assertTrue(fresh.exists())
        self.assertFalse((config.CACHE / "sub1").exists())
        self.assertEqual(self.count("embeddings", "sub1"), 1)        # Unterordner gelöscht: Stimmdaten bleiben
        self.assertEqual(r["forgotten"], 0)                          # schon im ersten Lauf (unter Lock) aufgeräumt
        shutil.rmtree(fresh)

    def test_cleanup_after_finder(self):
        from transcriber import cleanup
        a1, j1 = self.make("Nur Audio weg", "ddd4")
        a1.unlink()                                                  # im Finder: nur Audio gelöscht
        a2, j2 = self.make("Alles weg", "eee5")
        for p in self.rec.glob("Alles weg*"):
            p.unlink()                                               # im Finder: alles gelöscht
        a3, j3 = self.make("Verschoben", "fff6")
        sub = self.rec.parent / "Archiv"; sub.mkdir()
        for p in self.rec.glob("Verschoben*"):
            p.rename(sub / p.name)                                   # im Finder verschoben (Wächter noch nicht dran)
        gone_drive = Path("/Volumes/nicht-da-xyz/Aufnahme.m4a")      # Laufwerk abgemeldet: nichts anfassen
        self.db.execute("INSERT INTO jobs VALUES(?,?,?,?,?)", ("ggg7", str(gone_drive), str(gone_drive) + ".json", "m", 0))
        self.db.commit()
        r = cleanup.cleanup()
        self.assertFalse((config.CACHE / "ddd4").exists())
        self.assertEqual(self.count("embeddings", "ddd4"), 1)        # Transkript noch da → Stimmen bleiben
        # Audio und Transkript weg (evtl. nur archiviert): Zwischenspeicher und Eintrag weg, Stimmdaten bleiben (Björn 2026-10-28)
        self.assertFalse((config.CACHE / "eee5").exists())
        self.assertEqual((self.count("jobs", "eee5"), self.count("embeddings", "eee5"), self.count("clusters", "eee5")), (1, 1, 1))
        self.assertIsNotNone(self.db.execute("SELECT id FROM persons WHERE name='Person eee5'").fetchone())
        self.assertFalse((config.JOBS / "eee5.json").exists())
        self.assertEqual(self.count("embeddings", "fff6"), 1)
        self.assertEqual(self.db.execute("SELECT transcript FROM jobs WHERE id='fff6'").fetchone()[0],
                         str(sub / "Verschoben.transcript.json"))
        self.assertEqual(self.count("jobs", "ggg7"), 1)
        self.assertEqual((r["forgotten"], r["relinked"]), (1, 1))
        self.assertEqual(cleanup.cleanup()["forgotten"], 0)         # nächster Lauf: nichts mehr zu tun, keine Meldung

    def test_audio_after_days(self):
        """Ganzer Ordner samt Unterordnern, Audio und Video, gezählt ab dem Transkript (nicht ab dem Dateidatum)."""
        from transcriber import cleanup
        old, jo = self.make("Alt", None, days=40)
        new, jn = self.make("Neu", None)
        handy = self.make("Handy alt", None, folder=self.rec.parent / "Handy", days=40)[0]
        video = self.make("Webinar", None, folder=self.rec.parent / "Archiv" / "2026", ext=".mp4", days=40)[0]
        hidden = self.make("Versteckt", None, folder=self.rec.parent / ".stversions", days=40)[0]
        airdrop, _ = self.make("Altes Original", None, folder=self.rec.parent / "Handy")   # heute transkribiert
        reused, _ = self.make("Neue Aufnahme", None, days=40)
        reused.write_bytes(b"andere, noch nicht transkribierte Aufnahme")   # gleicher Name, neuer Inhalt
        link = self.rec / "Verweis.m4a"
        link.symlink_to(handy)                                       # Symlink: nie über ihn löschen
        link.with_name("Verweis.transcript.json").write_text(json.dumps({"source": str(link), "job_id": pipeline.job_id(handy),
                                                                          "created": "2020-01-01 00:00"}))
        untranscribed = self.rec / "Ohne Transkript.m4a"
        untranscribed.write_bytes(b"\0")
        t40 = time.time() - 40 * 86400
        for p in (old, untranscribed, airdrop, reused):
            os.utime(p, (t40, t40))
        r = cleanup.cleanup(audio_days=30)
        self.assertEqual(sorted(r["audio_deleted"]), sorted(map(str, (old, handy, video))))
        self.assertFalse(old.exists() or handy.exists() or video.exists())
        self.assertTrue(jo.exists() and new.exists() and untranscribed.exists() and hidden.exists() and airdrop.exists())
        self.assertTrue(reused.exists() and link.is_symlink())
        self.assertEqual(self.count("embeddings", json.loads(jo.read_text())["job_id"]), 1)


class TextFormat(unittest.TestCase):
    """Lesbares Transkript als .md oder .txt (Einstellung text_format); fremde Dateien gleichen Namens bleiben unberührt."""

    def setUp(self):
        set_lang("de")
        self.tmp = Path(tempfile.mkdtemp(dir=_DATA))
        self.audio = self.tmp / "Gespräch.m4a"
        self.audio.write_bytes(b"\0" * 16)
        self.doc = sample()
        self.doc["source"] = str(self.audio)

    def tearDown(self):
        config.CONFIG.unlink(missing_ok=True)

    def test_plain_text_has_no_markdown(self):
        txt = render.markdown(self.doc, "x.transcript.json", plain=True)
        self.assertNotIn("**", txt)
        self.assertNotIn("|", txt)
        self.assertNotIn("`", txt)
        self.assertFalse(txt.startswith("#"))
        self.assertRegex(txt, r"\n\[00:00:\d\d\] [^:]+: ")
        self.assertTrue(render.is_ours_text(txt, self.audio.name))

    def test_ours_despite_unicode_form(self):
        """Name vom Handy als NFD auf der Platte, Pfad getippt als NFC: trotzdem das eigene Transkript."""
        import unicodedata
        nfd = unicodedata.normalize("NFD", "Vortrag Björn.m4a")
        head = f"Vortrag Björn\n\nQuelle: {nfd} · 53:33 min\n"
        self.assertTrue(render.is_ours_text(head, unicodedata.normalize("NFC", nfd)))
        self.assertTrue(render.is_ours_text(unicodedata.normalize("NFC", head), nfd))

    def test_default_is_txt(self):
        config.CONFIG.unlink(missing_ok=True)
        self.assertEqual(render.write(self.doc, self.tmp / "Gespräch", ["md", "json"])["md"].name, "Gespräch.txt")

    def test_setting_txt_writes_txt(self):
        config.CONFIG.write_text(json.dumps({"text_format": "txt"}))
        paths = render.write(self.doc, self.tmp / "Gespräch", ["md", "json"])
        self.assertEqual(paths["md"].name, "Gespräch.txt")
        self.assertFalse((self.tmp / "Gespräch.md").exists())
        # Benennen/Neu auswerten behält das Format, auch wenn die Einstellung inzwischen anders ist
        config.CONFIG.write_text(json.dumps({"text_format": "md"}))
        self.assertEqual(render.write(self.doc, self.tmp / "Gespräch", ["md", "json"])["md"].name, "Gespräch.txt")

    def test_foreign_file_is_never_overwritten(self):
        config.CONFIG.write_text(json.dumps({"text_format": "md"}))
        foreign = self.tmp / "Gespräch.md"
        foreign.write_text("Notendatei eines anderen Programms")
        paths = render.write(self.doc, self.tmp / "Gespräch", ["md", "json"])
        self.assertEqual(foreign.read_text(), "Notendatei eines anderen Programms")
        self.assertEqual(paths["md"].name, "Gespräch.transcript.md")
        self.assertEqual(pipeline.load_doc(paths["md"])[1].name, "Gespräch.transcript.json")

    def test_rename_keeps_txt_and_foreign_files(self):
        config.CONFIG.write_text(json.dumps({"text_format": "txt"}))
        fresh_db()
        jp = render.write(self.doc, self.tmp / "Gespräch", ["md", "json"])["json"]
        (self.tmp / "Gespräch.md").write_text("fremd")              # gleichnamige fremde Datei
        config.CONFIG.write_text(json.dumps({"text_format": "md"}))
        pipeline.rename(jp, "Neu")
        self.assertEqual(sorted(p.name for p in self.tmp.iterdir()),
                         ["Gespräch.md", "Neu.m4a", "Neu.transcript.json", "Neu.txt"])
        self.assertEqual((self.tmp / "Gespräch.md").read_text(), "fremd")

    def test_enroll_reads_txt(self):
        from transcriber import enroll
        f = self.tmp / "benannt.txt"
        f.write_text(render.markdown(self.doc, "x.transcript.json", plain=True))
        self.assertTrue(enroll.parse_named(f))


class Hallucinations(unittest.TestCase):
    """drop_hallucinations: in Stille erfundene Phrasen weg, echte (auch leise) Wörter im Gespräch bleiben."""

    def test_rules(self):
        import soundfile as sf
        sr, n = 16000, 100
        rng = np.random.default_rng(0)
        a = np.full(sr * n, 0.0005, dtype=np.float32) * rng.standard_normal(sr * n).astype(np.float32)
        loud = lambda s, e: a.__setitem__(slice(int(s * sr), int(e * sr)), 0.1 * rng.standard_normal(int((e - s) * sr)).astype(np.float32))
        loud(0, 20); loud(39, 42); loud(59, 62); loud(69, 92)          # Gespräch, Geräusch bei 40, echtes Ende, Klopfen
        a[int(12 * sr):int(12.4 * sr)] *= 0.01                          # leises echtes Wort mitten im Gespräch
        wav = Path(tempfile.mkdtemp(dir=_DATA)) / "a.wav"
        sf.write(str(wav), a, sr)
        W = lambda t, w, d=0.4: {"w": w, "start": t, "end": t + d, "speaker": "S"}
        words = [W(x / 2, "wort") for x in range(0, 24)] + [W(12.0, "leise")] + [W(x / 2, "wort") for x in range(26, 40)]
        words += [W(25, "Kauderwelsch"),                                # (a) allein, leise, außerhalb
                  W(40, "Vielen"), W(40.4, "Dank."),                    # (c) Floskel außerhalb erkannter Sprache (Geräusch)
                  W(60, "Vielen"), W(60.4, "Dank."),                    # echt: Floskel, laut, in erkannter Sprache → bleibt
                  W(70, "Ja."), W(80, "Ja."), W(90, "Ja.")]             # (b) dreimal gleich allein → weg, obwohl laut
        unsure = lambda t, w: dict(W(t, w), p=0.05)
        words += [unsure(30 + i * 0.5, f"salat{i}") for i in range(8)]  # (d) lang, unsicher, außerhalb → weg
        words += [unsure(15.1, "nuschel")]                             # unsicher, aber im Gespräch → bleibt
        words.sort(key=lambda w: w["start"])
        segs = [{"start": 0, "end": 11.5, "speaker": "S"}, {"start": 12.5, "end": 20, "speaker": "S"},
                {"start": 59.5, "end": 61.5, "speaker": "S"}] + [{"start": t - 0.5, "end": t + 1, "speaker": "S"} for t in (70, 80, 90)]
        kept, dropped = pipeline.drop_hallucinations(words, segs, wav)
        gone = {d["text"]: d["why"] for d in dropped}
        self.assertEqual(gone.get("Kauderwelsch"), "a")
        self.assertIn("c", gone.get("Vielen Dank.", ""))
        self.assertEqual(sum(1 for d in dropped if d["text"] == "Ja."), 3)
        texts = [w["w"] for w in kept]
        self.assertIn("leise", texts)                                   # leise, aber mitten im Gespräch
        self.assertEqual([w["start"] for w in kept if w["w"] == "Vielen"], [60])   # das echte „Vielen Dank“ bleibt
        self.assertEqual(gone.get(" ".join(f"salat{i}" for i in range(8))), "d")
        self.assertIn("nuschel", texts)
        self.assertEqual(len(kept), len(words) - 1 - 2 - 3 - 8)

    def test_loops(self):
        W = lambda i, w: {"w": w, "start": i * 0.1, "end": i * 0.1 + 0.08}
        words = [W(0, "Das"), W(1, "ist")] + [W(2 + i, "Happy") for i in range(50)]
        words += [W(60 + i, w) for i, w in enumerate("Ja, ja, ja, ja, ja. Gut.".split())]
        words += [W(80 + i, w) for i, w in enumerate(("in der Bank, " * 12).split())]   # 3-Wort-Folge 12×
        kept, dropped = pipeline.drop_loops(words)
        texts = [w["w"] for w in kept]
        self.assertEqual(texts.count("Happy"), 1)
        self.assertEqual(texts.count("ja,") + texts.count("ja."), 4)    # echte Wiederholung (5×) bleibt ganz
        self.assertEqual(texts.count("Bank,"), 1)
        self.assertEqual([d["why"] for d in dropped], ["e", "e"])
        self.assertEqual(len(dropped[0]["text"].split()), 49)

    def test_nothing_without_diarization(self):
        w = [{"w": "x", "start": 0, "end": 1}]
        self.assertEqual(pipeline.drop_hallucinations(w, [], "egal.wav"), (w, []))


class Tracks(unittest.TestCase):
    """Zwei Spuren: wo gleichzeitig gesprochen wird bzw. wo die Mischung Wörter verschluckt hat."""

    def test_overlaps(self):
        seg = lambda s, e, spk="S": {"start": s, "end": e, "speaker": spk}
        mic = [seg(0, 10, "T1:A"), seg(20, 30, "T1:A"), seg(40, 45, "T1:E")]
        call = [seg(8, 9.5, "T2:B"), seg(24, 35, "T2:B"), seg(41, 44, "T2:B")]
        # 8–9,5 s: 1,5 s gleichzeitig → mit Rand; 24–30 s → mit Rand; 41–44 s ist Echo (T1:E) → nicht
        self.assertEqual(pipeline._overlaps(mic, call, echo={"T1:E"}), [(7.7, 9.8), (23.7, 30.3)])
        self.assertEqual(pipeline._overlaps([seg(0, 5)], [seg(4.5, 9)]), [])     # 0,5 s: kurzer Einwurf → Mischung

    def test_holes(self):
        w = lambda s, e: {"w": "x", "start": s, "end": e}
        words = [w(0, 1), w(1.2, 2), w(10, 11)]
        segs = [{"start": 3, "end": 8, "speaker": "T2:B"}, {"start": 12.5, "end": 13, "speaker": "T2:B"}]
        # 2–10 s ohne Wort, Spur spricht 3–8 s → Lücke; nach 11 s nur 0,5 s Sprache → keine
        self.assertEqual(pipeline._holes(words, segs, dur=14), [(3, 8)])

    def test_both_speaking_rejects_quiet_and_echo(self):
        rng = np.random.default_rng(0)
        a, b = rng.normal(0, 0.1, 32000).astype(np.float32), rng.normal(0, 0.1, 32000).astype(np.float32)
        self.assertTrue(pipeline._both_speaking(a, b, 0, 2))                  # zwei unabhängige Stimmen
        self.assertFalse(pipeline._both_speaking(a * 0.01, b, 0, 2))          # Mikrofon 40 dB leiser
        echo = (0.5 * np.concatenate([np.zeros(320, np.float32), b[:-320]])).astype(np.float32)
        self.assertFalse(pipeline._both_speaking(echo, b, 0, 2))              # Mikrofon = Echo der Call-Spur

    def test_merge_similar_keeps_expected_count(self):
        """Ähnliche Cluster werden zusammengelegt, aber nie unter `keep` (Call-Spur: erwartete Zahl anderer Personen)."""
        e = lambda *v: np.array(v + (0,) * (256 - len(v)), dtype=np.float32)
        mk = lambda: [{"label": "T2:A", "speech_s": 1000, "embedding": e(1, 0)},
                      {"label": "T2:B", "speech_s": 500, "embedding": e(0.8, 0.6)}]   # Ähnlichkeit 0,8
        segs = [{"start": 0, "end": 1, "speaker": "T2:B"}]
        self.assertEqual(len(pipeline._merge_similar(mk(), segs, [], 0.7)), 1)
        self.assertEqual(segs[0]["speaker"], "T2:A")
        segs = [{"start": 0, "end": 1, "speaker": "T2:B"}]
        self.assertEqual(len(pipeline._merge_similar(mk(), segs, [], 0.7, keep=2)), 2)
        self.assertEqual(segs[0]["speaker"], "T2:B")

    def test_absorb_fragments(self):
        """Call-Spur: Cluster aus Bruchstücken (Ø < 1 s) auflösen – Wörter während eigener Sprache an einen selbst,
        sonst an die ähnlichste echte Stimme; echte kurze Stimmen und sicher erkannte Personen bleiben."""
        fresh_db()
        seg = lambda s, e, spk: {"start": s, "end": e, "speaker": spk}
        w = lambda t, spk: {"w": "x", "start": t, "end": t + 0.2, "speaker": spk}
        e = lambda *v: np.array(v + (0,) * (256 - len(v)), dtype=np.float32)
        clusters = [{"label": "T2:J", "speech_s": 600, "embedding": e(1, 0, 0)},
                    {"label": "T2:G", "speech_s": 300, "embedding": e(0, 1, 0)},
                    {"label": "T2:F", "speech_s": 8, "embedding": e(0.2, 0.9, 0.1)}]       # Bruchstücke, eher G
        segs = ([seg(i * 10, i * 10 + 4, "T2:J") for i in range(150)] + [seg(5, 8, "T2:G")] * 100
                + [seg(20 + i, 20.4 + i, "T2:F") for i in range(20)])
        mine = [seg(30, 32, "T1:A")]
        words = [w(20.1, "T2:F"), w(30.5, "T2:F"), w(1, "T2:J")]
        n = pipeline._absorb_fragments(clusters, segs, words, mine, "T1:A", config.load())
        self.assertEqual(n, 1)
        self.assertEqual([x["speaker"] for x in words], ["T2:G", "T1:A", "T2:J"])
        # Ø 3 s je Abschnitt: echte (kurze) Stimme → bleibt
        words = [w(20.1, "T2:F")]
        long_ = [seg(20 + i * 3, 23 + i * 3, "T2:F") for i in range(3)]
        self.assertEqual(pipeline._absorb_fragments(clusters, segs[:250] + long_, words, mine, "T1:A", config.load()), 0)
        self.assertEqual(words[0]["speaker"], "T2:F")


class VoiceDatabase(unittest.TestCase):
    def test_sure_thresholds_by_speaking_time(self):
        cfg = config.load()
        cases = [(0.99, 14, False), (0.74, 30, False), (0.75, 30, True), (0.74, 60, False), (0.75, 60, True),
                 (0.65, 600, False)]
        for score, secs, want in cases:
            self.assertEqual(speakers.sure_match(score, secs, cfg), want, (score, secs))

    def test_first_name_resolves_to_single_person(self):
        db = fresh_db()
        speakers.person_id(db, "Kim Beispiel")
        self.assertEqual(speakers.resolve_name(db, "Kim"), "Kim Beispiel")
        speakers.person_id(db, "Kim Anders")
        self.assertEqual(speakers.resolve_name(db, "Kim"), "Kim")          # zwei Kims: nicht raten

    def test_rerun_moves_confirmations_to_new_labels(self):
        """Neuauswertung: Labels wechseln; Bestätigungen wandern mit, gemischte Gruppen vererben ihren Namen nicht."""
        db = fresh_db()
        rng = np.random.default_rng(2)
        alex, kim, sam = (rng.normal(size=192) for _ in range(3))
        sid, bid = speakers.person_id(db, "Alex Probe"), speakers.person_id(db, "Kim Probe")
        for pid, vec, secs, label in ((sid, alex, 407, "SPEAKER_02"), (bid, kim + sam, 541, "SPEAKER_00")):
            db.execute("INSERT INTO embeddings(person_id, vec, speech_s, job_id, label, origin) VALUES(?,?,?,?,?,?)",
                       (pid, speakers._unit(vec).tobytes(), secs, "job1", label, "named"))
        db.commit()
        new = [{"label": "SPEAKER_01", "speech_s": 403, "embedding": alex + rng.normal(size=192) * 0.05},
               {"label": "SPEAKER_02", "speech_s": 154, "embedding": kim},
               {"label": "SPEAKER_03", "speech_s": 389, "embedding": sam}]
        old = speakers.release_job_refs(db, "job1")
        speakers.identify(db, new, config.load())
        speakers.carry_refs(db, "job1", "a.m4a", old, new)
        db.commit()
        self.assertEqual([(c["label"], c["name"], c["status"]) for c in new],
                         [("SPEAKER_01", "Alex Probe", "bestätigt"), ("SPEAKER_02", None, "unbekannt"),
                          ("SPEAKER_03", None, "unbekannt")])
        refs = db.execute("SELECT person_id, label FROM embeddings WHERE job_id='job1'").fetchall()
        self.assertEqual([tuple(r) for r in refs], [(sid, "SPEAKER_01")])   # alte Alex-/Mischreferenz weg

    def test_voices_export_import_roundtrip(self):
        """Weitergeben: nur ausgewählte Personen, je ein Abdruck ohne Pfade; Import erkennt die Stimme, ein zweiter
        Import ersetzt den ersten, eigene Referenzen bleiben."""
        db = fresh_db()
        rng = np.random.default_rng(4)
        kim, alex = rng.normal(size=192), rng.normal(size=192)
        for name, v in (("Kim Beispiel", kim), ("Alex Muster", alex)):
            for _ in range(2):
                db.execute("INSERT INTO embeddings(person_id, vec, speech_s, source, origin) VALUES(?,?,?,?,?)",
                           (speakers.person_id(db, name), speakers._unit(v + rng.normal(size=192) * 0.1).tobytes(), 90,
                            "/geheim/Termin XY.m4a", "named"))
        db.commit()
        d = speakers.export_voices(db, ["Kim"])                       # Vorname genügt
        self.assertEqual([p["name"] for p in d["persons"]], ["Kim Beispiel"])
        self.assertNotIn("geheim", json.dumps(d))
        f = Path(tempfile.mkdtemp(dir=_DATA)) / "stimmen.voices.json"
        f.write_text(json.dumps(d))

        db = fresh_db()                                               # anderer Rechner
        own = speakers.person_id(db, "Kim Beispiel")
        db.execute("INSERT INTO embeddings(person_id, vec, speech_s, origin) VALUES(?,?,?,?)",
                   (own, speakers._unit(kim).tobytes(), 30, "named"))
        db.commit()
        for _ in range(2):
            self.assertEqual(speakers.import_voices(db, speakers.read_voices(f), source=f.name), [("Kim Beispiel", "ergänzt")])
        self.assertEqual([tuple(r) for r in db.execute("SELECT origin FROM embeddings ORDER BY origin")], [("imported",), ("named",)])
        probe = [{"label": "SPEAKER_00", "speech_s": 120, "embedding": kim + rng.normal(size=192) * 0.1}]
        speakers.identify(db, probe, config.load())
        self.assertEqual((probe[0]["name"], probe[0]["status"]), ("Kim Beispiel", "sicher"))
        self.assertEqual(speakers.import_voices(db, speakers.read_voices(f), skip_existing=True), [("Kim Beispiel", "übersprungen")])
        f.write_text(json.dumps(dict(d, embedding="anderes/modell")))
        with self.assertRaises(ValueError):
            speakers.read_voices(f)

    def test_nfd_and_nfc_are_the_same_person(self):
        db = fresh_db()
        a = speakers.person_id(db, unicodedata.normalize("NFC", "Jörg Müller"))
        b = speakers.person_id(db, unicodedata.normalize("NFD", "Jörg Müller"))
        self.assertEqual(a, b)
        self.assertEqual(len(speakers.persons(db)), 1)


class Glossary(unittest.TestCase):
    def test_replacements(self):
        f = Path(_DATA) / "vocab.txt"
        f.write_text("ACME = Akme, A.C.M.E.\nMuster AG = Muster A G\nNurListe\n# Kommentar\n")
        terms, rules = glossary.load(f)
        self.assertEqual(terms, ["ACME", "Muster AG", "NurListe"])
        self.assertEqual(glossary.apply_text("Die akme und die Muster A G, sowie A.C.M.E.", rules),
                         "Die ACME und die Muster AG, sowie ACME.")   # Satzzeichen am Wortende bleibt
        words = [{"w": w, "start": i, "end": i + 0.5} for i, w in enumerate("Die Akme-Strategie, Akme-.".split())]
        self.assertEqual(glossary.apply(words, rules), 2)
        self.assertEqual([w["w"] for w in words], ["Die", "ACME-Strategie,", "ACME-."])

    def test_apply_to_transcript(self):
        """vocab --apply: fertiges Transkript nachträglich ersetzen, neu schreiben; ohne Treffer bleibt die Datei."""
        set_lang("de")
        tmp = Path(tempfile.mkdtemp(dir=_DATA))
        doc = sample()
        doc["source"] = str(tmp / "a.m4a")
        jp = tmp / "a.transcript.json"
        jp.write_text(json.dumps(doc, ensure_ascii=False))
        (Path(_DATA) / "vocab.txt").write_text("Budgetplan = Budget\n")
        self.assertEqual(pipeline.apply_glossary(jp), 1)
        new = json.loads(jp.read_text())
        self.assertIn("Budgetplan.", [w["w"] for w in new["words"]])
        self.assertEqual(new["glossary_replacements"], 1)
        self.assertIn("Budgetplan.", (tmp / "a.txt").read_text())
        mtime = jp.stat().st_mtime_ns
        self.assertEqual(pipeline.apply_glossary(jp), 0)
        self.assertEqual(jp.stat().st_mtime_ns, mtime)

    def test_add_entries(self):
        f = Path(tempfile.mkdtemp(dir=_DATA)) / "vocab.txt"
        f.write_text("# Kopf\nACME = Akme  # Kunde\nNurListe\n")
        self.assertEqual(glossary.add(f, "acme", ["Akme", "Ack Me"]), ({"term": "ACME", "variants": ["Akme", "Ack Me"]}, True))
        self.assertEqual(glossary.add(f, "ACME", ["akme"])[1], False)              # schon da
        self.assertEqual(glossary.add(f, "KI", ["Kali", "KI"])[0], {"term": "KI", "variants": ["Kali"]})   # Begriff selbst nicht
        self.assertEqual(f.read_text(), "# Kopf\nACME = Akme, Ack Me  # Kunde\nNurListe\nKI = Kali\n")
        self.assertEqual(glossary.entries(f)[2], {"term": "KI", "variants": ["Kali"]})
        with self.assertRaises(ValueError):
            glossary.add(f, " # ", ["x"])

    def test_mcp_tools(self):
        """MCP: anzeigen, ergänzen, anwenden – über den Server aufgerufen wie von einem Client."""
        import asyncio
        from transcriber import mcp_server
        set_lang("de")
        (Path(_DATA) / "vocab.txt").unlink(missing_ok=True)
        tmp = Path(tempfile.mkdtemp(dir=_DATA))
        doc = sample()
        doc["source"] = str(tmp / "a.m4a")
        jp = tmp / "a.transcript.json"
        jp.write_text(json.dumps(doc, ensure_ascii=False))
        call = lambda name, **kw: asyncio.run(mcp_server.mcp.call_tool(name, kw))
        text = lambda r: r.content[0].text
        self.assertEqual(json.loads(text(call("show_glossary"))), [])
        self.assertTrue(json.loads(text(call("add_to_glossary", term="Budgetplan", misrecognized=["Budget"])))["changed"])
        self.assertEqual(json.loads(text(call("show_glossary"))), [{"term": "Budgetplan", "variants": ["Budget"]}])
        self.assertEqual(text(call("apply_glossary", transcript=str(jp))), "1 Ersetzungen")
        self.assertEqual(text(call("apply_glossary", transcript=str(jp))), "0 Ersetzungen")


class Repair(unittest.TestCase):
    """asr._flat_spans / accept: nur lange Stellen ohne Satzzeichen, Übernahme nur bei gleichem Inhalt."""

    def test_flat_spans(self):
        from transcriber import asr
        S = lambda a, b, t: {"start": a, "end": b, "text": t}
        segs = [S(0, 5, "Guten Morgen, wir fangen an."), S(5, 10, "und dann haben wir " * 4), S(10, 15, "das budget gesehen " * 4),
                S(15, 20, "Gut."), S(20, 25, "nur kurz ohne punkt")]
        self.assertEqual(asr._flat_spans(segs), [(5, 15)])          # 28 Wörter am Stück; der kurze Rest zählt nicht
        self.assertEqual(asr._flat_spans(segs, min_words=30), [])

    def test_accept(self):
        from transcriber import asr
        W = lambda t, p=0.8: [{"w": x, "start": i, "end": i + 0.5, "p": p} for i, x in enumerate(t.split())]
        old = W("ich habe mal eines herausgepickt ein einfaches beispiel aber das kannst du dir zeigen")
        good = W("Ich habe mal eines herausgepickt, ein einfaches Beispiel, aber das kannst du dir zeigen.")
        self.assertTrue(asr.accept(old, good)[0])
        self.assertFalse(asr.accept(old, W("Ja, genau."))[0])                  # Inhalt verloren
        self.assertFalse(asr.accept(old, W(good and "I picked one, a simple example, but you can show it.", 0.9))[0])  # übersetzt
        self.assertFalse(asr.accept(old, W("Ich habe mal eines herausgepickt, ein einfaches Beispiel, aber das kannst du dir zeigen.", 0.6))[0])  # unsicherer
        self.assertFalse(asr.accept(old, old)[0])                               # keine Satzzeichen gewonnen
        self.assertEqual([w["w"] for w in asr._strip_thanks(W("Das war es. Vielen Dank."))], ["Das", "war", "es."])


class Language(unittest.TestCase):
    def tearDown(self):
        config.CONFIG.unlink(missing_ok=True)
        set_lang("de")

    def test_env_wins_over_config(self):
        config.CONFIG.write_text(json.dumps({"ui_language": "de"}))
        set_lang("en")
        self.assertEqual(i18n.t("ja", "yes"), "yes")

    def test_config_when_no_env(self):
        config.CONFIG.write_text(json.dumps({"ui_language": "en"}))
        os.environ.pop("TRANSCRIBER_UI_LANG")
        i18n.lang.cache_clear()
        self.assertEqual(i18n.lang(), "en")

    def test_status_display(self):
        set_lang("en")
        self.assertEqual([i18n.status(s) for s in ("sicher", "bestätigt", "vermutlich", "unbekannt")],
                         ["confident", "confirmed", "probably", "unknown"])
        set_lang("de")
        self.assertEqual(i18n.status("sicher"), "sicher")


class ProgressStatus(unittest.TestCase):
    def test_concurrent_emit(self):
        """Hauptthread und _tick schreiben dieselbe Statusdatei – darf nicht mit FileNotFoundError scheitern (2026-10-23)."""
        import threading
        P = pipeline.Progress(None, Path(_DATA) / "x.m4a")
        P.start("asr", expected_s=60)
        errors = []

        def hammer():
            try:
                for _ in range(300):
                    P._emit(0.5, "x")
            except Exception as e:
                errors.append(e)
        ts = [threading.Thread(target=hammer) for _ in range(4)]
        [t.start() for t in ts]
        [t.join() for t in ts]
        P.done({})
        self.assertEqual(errors, [])
        self.assertEqual(json.loads(P.path.read_text())["state"], "done")


class Library(unittest.TestCase):
    """Fenster „Alle Transkriptionen“: Aufnahmedatum ohne Audio aus Termin bzw. Dateiname, Unterordner, offene Sprecher."""

    def test_entries(self):
        from transcriber import library
        root = Path(tempfile.mkdtemp())
        (root / "Handy").mkdir()
        (root / ".stversions").mkdir()
        doc = {"source": str(root / "Handy" / "gone.m4a"), "created": "2026-10-24 12:00", "duration": 600,
               "event": {"title": "Termin", "start": "2026-10-01T08:00:00Z"},
               "speakers": [{"letter": "A", "display": "Kim Beispiel", "status": "bestätigt", "speech_s": 300},
                            {"letter": "B", "display": "Sprecher B", "status": "unbekannt", "speech_s": 200},
                            {"letter": "C", "display": "Sprecher C", "status": "unbekannt", "speech_s": 3}]}
        (root / "Handy" / "gone.transcript.json").write_text(json.dumps(doc))
        doc2 = dict(doc, source=str(root / "2026-09-30 14-05 Runde.m4a"), event=None)
        (root / "2026-09-30 14-05 Runde.transcript.json").write_text(json.dumps(doc2))
        (root / ".stversions" / "alt.transcript.json").write_text(json.dumps(doc2))   # versteckte Ordner nicht
        es = {e["title"]: e for e in library.entries(root)}
        self.assertEqual(set(es), {"gone", "2026-09-30 14-05 Runde"})
        g = es["gone"]
        self.assertEqual((g["folder"], g["audio"], g["recorded_from"], g["open"]), ("Handy", False, "event", 1))
        self.assertTrue(g["recorded"].startswith("2026-10-01 "))
        self.assertEqual(g["speakers"], ["Kim Beispiel", "Sprecher B", "Sprecher C"])
        r = es["2026-09-30 14-05 Runde"]
        self.assertEqual((r["folder"], r["recorded"], r["recorded_from"]), ("", "2026-09-30 14:05", "name"))
        shutil.rmtree(root)

    def test_recorded_from_custom_name_formats(self):
        """Einstellbares Datumsformat der App: yyMMdd HHmm, yyyyMMdd HHmm, Standardname – sonst kein Datum aus dem Namen."""
        from transcriber import library
        root = Path(tempfile.mkdtemp(dir=_DATA))
        doc = {"created": "2026-11-01 09:00"}
        for name, want in [("261030 1403 Budget.m4a", ("2026-10-30 14:03", "name")),
                           ("20261030 1403 Budget.m4a", ("2026-10-30 14:03", "name")),
                           ("Aufnahme 261030 1403.m4a", ("2026-10-30 14:03", "name")),
                           ("261399 1403 Budget.m4a", ("2026-11-01 09:00", "transcript")),   # kein gültiges Datum
                           ("Projekt 12345 Notizen.m4a", ("2026-11-01 09:00", "transcript"))]:
            self.assertEqual(library.recorded(doc, root / name, {}), want, name)


class AsrModel(unittest.TestCase):
    """Modellwahl turbo / turbo-8bit (config „asr_model“): Standard, Ordner mit Verweisen für 8 Bit, eigener
    Zwischenspeicher-Schlüssel – ohne Netz und ohne echtes Modell (snapshot_download wird ersetzt)."""

    def setUp(self):
        from transcriber import asr
        self.asr = asr
        self.snap = Path(tempfile.mkdtemp(dir=_DATA))
        (self.snap / "model.safetensors").write_bytes(b"w")
        (self.snap / "config.json").write_text("{}")
        import huggingface_hub
        self._orig = huggingface_hub.snapshot_download
        huggingface_hub.snapshot_download = lambda repo, local_files_only=True: str(self.snap)

    def tearDown(self):
        import huggingface_hub
        huggingface_hub.snapshot_download = self._orig
        config.CONFIG.unlink(missing_ok=True)
        shutil.rmtree(config.DATA / "models", ignore_errors=True)

    def test_default_and_unknown(self):
        orig = self.asr.installed
        try:
            for have, want in ((set(), "turbo-8bit"), ({"turbo"}, "turbo"), ({"turbo", "turbo-8bit"}, "turbo-8bit"),
                               ({"turbo-8bit"}, "turbo-8bit")):
                self.asr.installed = lambda k, h=have: k in h
                self.assertEqual(self.asr.choice({}), want, have)            # neu: 8 Bit; nur FP16 da: bleibt FP16
                self.assertEqual(self.asr.choice({"asr_model": "gibt-es-nicht"}), want, have)
            self.assertEqual(self.asr.choice({"asr_model": "turbo-8bit"}), "turbo-8bit")   # Eingestelltes gilt
        finally:
            self.asr.installed = orig
        cfg = {"asr_model": "turbo"}
        self.assertEqual(self.asr.path(cfg), "mlx-community/whisper-large-v3-turbo")
        self.assertEqual(self.asr.name(cfg), "whisper-turbo")

    def test_remove_unused_only(self):
        import huggingface_hub.constants as c
        cache = Path(tempfile.mkdtemp(dir=_DATA))
        orig, c.HF_HUB_CACHE = c.HF_HUB_CACHE, str(cache)
        try:
            config.CONFIG.write_text(json.dumps({"asr_model": "turbo-8bit"}))
            self.asr.path()                                                   # Ordner mit Verweisen für 8 Bit
            for rev, repo in (("a1", "whisper-large-v3-turbo"), ("b2", "whisper-large-v3-turbo-8bit")):  # wie im HF-Cache
                r = cache / f"models--mlx-community--{repo}"
                for d in ("blobs", "refs", f"snapshots/{rev}"):
                    (r / d).mkdir(parents=True)
                (r / "blobs" / "h1").write_bytes(b"1234")
                (r / "refs" / "main").write_text(rev)               # Revisionen sind eindeutig, gelöscht wird nach ihnen
                (r / "snapshots" / rev / "weights.safetensors").symlink_to("../../blobs/h1")
            with self.assertRaises(RuntimeError):
                self.asr.remove("turbo-8bit")                                 # eingestelltes nie
            self.assertEqual(self.asr.remove("turbo"), 4)
            self.assertFalse((cache / "models--mlx-community--whisper-large-v3-turbo").exists())
            self.assertTrue((cache / "models--mlx-community--whisper-large-v3-turbo-8bit").exists())
            config.CONFIG.write_text(json.dumps({"asr_model": "turbo"}))
            self.asr.remove("turbo-8bit")                                     # auch der Ordner mit Verweisen
            self.assertFalse(self.asr.local_dir("turbo-8bit").exists())
        finally:
            c.HF_HUB_CACHE = orig

    def test_8bit_folder_for_mlx_whisper(self):
        cfg = {"asr_model": "turbo-8bit"}
        d = Path(self.asr.path(cfg))
        self.assertEqual(d, config.DATA / "models" / "whisper-large-v3-turbo-8bit")
        self.assertEqual((d / "weights.safetensors").resolve(), (self.snap / "model.safetensors").resolve())
        self.assertEqual((d / "config.json").resolve(), (self.snap / "config.json").resolve())
        self.assertEqual(self.asr.path(cfg), str(d))          # zweites Mal: Verweise bleiben, kein Fehler
        self.assertEqual(self.asr.name(cfg), "whisper-turbo-8bit")

    def test_missing_model_explains(self):
        import huggingface_hub
        def missing(repo, local_files_only=True):
            raise OSError("nicht im Cache")
        huggingface_hub.snapshot_download = missing
        with self.assertRaises(RuntimeError) as e:
            self.asr.path({"asr_model": "turbo-8bit"})
        self.assertIn("transcriber model turbo-8bit --download", str(e.exception))
        self.assertFalse(self.asr.installed("turbo-8bit"))

    def test_cache_not_shared_between_models(self):
        wav = Path(tempfile.mkdtemp(dir=_DATA)) / "audio.wav"
        calls = []
        orig = self.asr.transcribe
        self.asr.transcribe = lambda w, terms=None, language="de": calls.append(self.asr.name()) or {
            "text": "x", "words": [], "segments": []}
        try:
            config.CONFIG.write_text(json.dumps({"asr_model": "turbo"}))
            pipeline._asr(wav, "de", None, repair=False)
            pipeline._asr(wav, "de", None, repair=False)            # aus dem Zwischenspeicher
            config.CONFIG.write_text(json.dumps({"asr_model": "turbo-8bit"}))
            pipeline._asr(wav, "de", None, repair=False)            # anderes Modell → neu erkennen
        finally:
            self.asr.transcribe = orig
        self.assertEqual(calls, ["whisper-turbo", "whisper-turbo-8bit"])

    def test_update_switches_fp16_once(self):
        """0.11: Update stellt FP16 einmal auf 8 Bit um; danach bleibt eine bewusste FP16-Wahl."""
        self.assertTrue(self.asr.default_switch({"asr_model": "turbo"}))
        self.assertFalse(self.asr.default_switch({"asr_model": "turbo-8bit"}))
        self.assertFalse(self.asr.default_switch({"asr_model": "turbo", "asr_8bit_switch": "2026-10-29"}))

    def test_fresh_skips_cache(self):
        """„Audio neu transkribieren“ / „Erneut transkribieren“: Spracherkennung neu, Zwischenspeicher danach erneuert."""
        wav = Path(tempfile.mkdtemp(dir=_DATA)) / "audio.wav"
        calls = []
        orig = self.asr.transcribe
        self.asr.transcribe = lambda w, terms=None, language="de": calls.append(1) or {
            "text": f"x{len(calls)}", "words": [], "segments": []}
        try:
            pipeline._asr(wav, "de", None, repair=False)
            pipeline._asr(wav, "de", None, repair=False)                       # Zwischenspeicher
            r = pipeline._asr(wav, "de", None, repair=False, fresh=True)       # neu
            again = pipeline._asr(wav, "de", None, repair=False)               # jetzt das neue Ergebnis
        finally:
            self.asr.transcribe = orig
        self.assertEqual(len(calls), 2)
        self.assertEqual((r["text"], again["text"]), ("x2", "x2"))


class Summary(unittest.TestCase):
    """Zusammenfassung (feature/ki-nachbearbeitung): Vorlagen, Namen vor der Cloud, Ergebnisdatei – ohne Modell, ohne Netz."""

    def setUp(self):
        from transcriber import summarize
        self.s = summarize
        set_lang("de")
        self.tmp = Path(tempfile.mkdtemp(dir=_DATA))
        self.doc = sample()
        self.doc["source"] = str(self.tmp / "Gespräch.m4a")
        (self.tmp / "Gespräch.m4a").write_bytes(b"\0")
        self.jp = render.write(self.doc, self.tmp / "Gespräch", ["json"])["json"]
        config.CONFIG.write_text(json.dumps({"ai": {"provider": "mtplx", "model": "test"}}))
        self._complete = summarize.complete
        self.sent = []

        def fake(s, system, user):
            self.sent.append((s, user))
            return ("<think>hm</think>## Kernpunkte\n- Kim Beispiel (?) und Sprecher C reden\n\n## Aufgaben\n"
                    "- [ ] Sprecher C: Bericht schicken\n- [ ] Alex Muster: Termin\n- [ ] dritte"), \
                {"seconds": 1.0, "prompt_tokens": 10, "completion_tokens": 5, "model": "test"}
        summarize.complete = fake

    def tearDown(self):
        self.s.complete = self._complete
        config.CONFIG.unlink(missing_ok=True)

    def test_templates_both_languages(self):
        for lang in ("de", "en"):
            set_lang(lang)
            ts = self.s.templates()
            self.assertEqual(list(ts)[:6], ["protokoll", "kurzfassung", "auftrag", "supervision", "kernaussagen", "email"])
            for x in ts.values():
                self.assertIn("{{transcript}}", x["body"])
                self.assertTrue(x["name"] and x["description"])
        set_lang("de")

    def test_custom_template_overrides(self):
        self.s.user_dir().mkdir(parents=True, exist_ok=True)
        (self.s.user_dir() / "protokoll.md").write_text("---\nname: Mein Protokoll\n---\nKurz bitte.\n")
        try:
            tpl = self.s.get_template("protokoll")
            self.assertEqual((tpl["name"], tpl["custom"], tpl["builtin"]), ("Mein Protokoll", True, True))
            self.assertTrue(self.s.fill(tpl["body"], {"transcript": "T"}).rstrip().endswith("T"))   # angehängt
        finally:
            shutil.rmtree(self.s.user_dir())

    def test_run_local_writes_file(self):
        out, meta = self.s.run(self.jp)
        self.assertEqual(out.name, "Gespräch.summary.md")
        self.assertTrue(meta["local"] and not meta["pseudonymized"])
        user = self.sent[0][1]
        self.assertIn("Kim Beispiel", user)                       # lokal: Namen bleiben
        self.assertIn("] Alex Muster: ", user)                     # Redebeiträge wie im Transkript
        text = out.read_text()
        self.assertNotIn("<think>", text)
        self.assertEqual(self.s.read_meta(out)["template"], "protokoll")
        self.assertEqual(self.s.preview(out), {"points": ["Kim Beispiel (?) und Sprecher C reden"],
                                               "tasks": ["Sprecher C: Bericht schicken", "Alex Muster: Termin"],
                                               "text": ""})
        # Fließtext (Kurzfassung): erster Absatz statt Stichpunkten, ohne Überschrift und Hervorhebung
        out.write_text(out.read_text().split("\n", 1)[0] + "\n## Kurz\n\n**Kim** und Alex reden.\nEs geht um X.\n\nZweiter.\n")
        self.assertEqual(self.s.preview(out), {"points": [], "tasks": [], "text": "Kim und Alex reden. Es geht um X."})

    def test_cloud_pseudonymized_and_only_on_click(self):
        config.CONFIG.write_text(json.dumps({"ai": {"provider": "openai", "model": "x"}}))
        os.environ["TRANSCRIBER_AI_KEY"] = "test"
        try:
            with self.assertRaises(RuntimeError):
                self.s.run(self.jp, allow_cloud=False)
            out, meta = self.s.run(self.jp)
        finally:
            del os.environ["TRANSCRIBER_AI_KEY"]
        user = self.sent[-1][1]
        for n in ("Alex", "Kim", "Muster", "Beispiel"):
            self.assertNotIn(n, user)
        self.assertTrue(meta["pseudonymized"] and not meta["local"])
        self.assertIn("Alex Muster: Termin", out.read_text())       # Antwort mit echten Namen zurück (Platzhalter → Name)

    def test_names_follow_naming_and_rename(self):
        self.s.run(self.jp)
        db = fresh_db()
        speakers.save_job(db, self.doc["job_id"], self.doc["source"], self.jp, self.doc["model"],
                          [dict(c, embedding=np.ones(4, np.float32)) for c in self.doc["speakers"]])
        pipeline.name_speaker(self.jp, "C", "Robin Test")
        text = (self.tmp / "Gespräch.summary.md").read_text()
        self.assertIn("- [ ] Robin Test: Bericht schicken", text)
        self.assertNotIn("Sprecher C", text)
        paths = pipeline.rename(self.jp, "Neu")
        self.assertTrue((self.tmp / "Neu.summary.md").exists())
        self.assertFalse((self.tmp / "Gespräch.summary.md").exists())
        from transcriber import cleanup
        self.assertIn(self.tmp / "Neu.summary.md", cleanup._transcript_files(paths["json"], paths["source"]))   # „Alles löschen“

    def test_rename_case_only(self):
        """Nur die Groß-/Kleinschreibung ändern: kein „… 2“, nichts geht verloren (macOS-Dateisystem ignoriert sie)."""
        self.s.run(self.jp)
        fresh_db()
        render.write(self.doc, self.tmp / "Gespräch", ["md", "json"])
        pipeline.rename(self.jp, "GESPRÄCH")
        self.assertEqual(sorted(p.name for p in self.tmp.iterdir()),
                         ["GESPRÄCH.m4a", "GESPRÄCH.summary.md", "GESPRÄCH.transcript.json", "GESPRÄCH.txt"])
        self.assertEqual(json.loads((self.tmp / "GESPRÄCH.transcript.json").read_text())["source"], str(self.tmp / "GESPRÄCH.m4a"))

    def test_foreign_file_not_overwritten(self):
        (self.tmp / "Gespräch.summary.md").write_text("eigene Notiz")
        with self.assertRaises(RuntimeError):
            self.s.run(self.jp)
        self.assertEqual((self.tmp / "Gespräch.summary.md").read_text(), "eigene Notiz")

    def test_thinking_only_answer_retried_with_prefill(self):
        """LM Studio ignoriert enable_thinking: nur Nachdenken, leerer Text → zweiter Versuch mit leerem Nachdenk-Block."""
        calls = []

        def fake_request(s, path, payload=None, timeout=10):
            calls.append(payload["messages"])
            prefilled = payload["messages"][-1]["role"] == "assistant"
            msg = {"content": "## Kernpunkte\n- A"} if prefilled else {"content": "", "reasoning_content": "Thinking …"}
            return {"choices": [{"message": msg}], "usage": {}}
        orig, self.s._request = self.s._request, fake_request
        try:
            text, _ = self._complete(self.s.settings({"ai": {"provider": "ollama", "model": "m"}}), "sys", "user")
            self.assertEqual((text, len(calls)), ("## Kernpunkte\n- A", 2))
            calls.clear()                                     # LM Studio: gleich mit Block, kein Fehlversuch
            self._complete(self.s.settings({"ai": {"provider": "lmstudio", "model": "m"}}), "sys", "user")
            self.assertEqual((len(calls), calls[0][-1]), (1, self.s.PREFILL))
        finally:
            self.s._request = orig

    def test_openai_reasoning_model_parameters(self):
        """GPT-5/o-Modelle: 400 wegen max_tokens/temperature → zweiter Versuch mit max_completion_tokens, ohne temperature."""
        sent = []

        def fake_request(s, path, payload=None, timeout=10):
            sent.append(dict(payload))
            if "max_tokens" in payload:
                raise RuntimeError("https://api.openai.com/v1: HTTP 400 Unsupported parameter: 'max_tokens' … use 'max_completion_tokens'")
            return {"choices": [{"message": {"content": "ok"}}], "usage": {}}
        orig, self.s._request = self.s._request, fake_request
        try:
            text, _ = self._complete(self.s.settings({"ai": {"provider": "openai", "model": "gpt-5"}}), "sys", "user")
        finally:
            self.s._request = orig
        self.assertEqual(text, "ok")
        self.assertIn("max_completion_tokens", sent[1])
        self.assertNotIn("temperature", sent[1])

    def test_pseudonymize_forms(self):
        """NFC, wie geschrieben oder GROSS, Genitiv; klein nicht („hell“ bei Person „Hell“); Artikel nie allein; „Januar“."""
        doc = {"speakers": [{"name": unicodedata.normalize("NFD", "Jörg van der Berg")}],
               "event": {"attendees": [{"name": "Jan Ohm"}, {"name": "Eva Hell"}]}}
        text = "Jörgs Notiz, Jörg's Plan, JÖRG sagt: van der Berg kommt; der Plan von Jan im Januar, hell. Robin auch."
        out, back = self.s.pseudonymize(text, doc, ["Robin Muster"])
        for n in ("Jörg", "JÖRG", "Berg", "Jan ", "Robin"):
            self.assertNotIn(n, out)
        self.assertIn("Januar, hell.", out)                 # gewöhnliches Wort bleibt
        self.assertIn("der Plan von [P", out)
        self.assertIn("im Januar", out)
        self.assertRegex(out, r"^\[P\d+\]s Notiz, \[P\d+\]'s Plan")
        self.assertTrue(self.s.restore(out, back).startswith("Jörgs Notiz, Jörg's Plan, Jörg sagt: van der Berg"))
        self.assertEqual(self.s.fill("Bitte: {{ transcript }}", {"transcript": "T"}), "Bitte: T")   # nicht doppelt

    def test_cloud_title_and_database_names(self):
        """Titel (Dateiname) und Personen der Stimmdatenbank gehen nicht in die Cloud."""
        db = fresh_db()
        speakers.person_id(db, "Robin Extern"); db.commit(); db.close()
        doc = dict(self.doc, source=str(self.tmp / "Robin Extern Gespräch.m4a"))
        (self.tmp / "Robin Extern Gespräch.m4a").write_bytes(b"\0")
        jp = render.write(doc, self.tmp / "Robin Extern Gespräch", ["json"])["json"]
        config.CONFIG.write_text(json.dumps({"ai": {"provider": "openai", "model": "x"}}))
        os.environ["TRANSCRIBER_AI_KEY"] = "test"
        try:
            self.s.run(jp)
        finally:
            del os.environ["TRANSCRIBER_AI_KEY"]
        self.assertNotIn("Robin", self.sent[-1][1])
        self.assertNotIn("Extern", self.sent[-1][1])

    def test_mcp_cloud_only_with_cloud_auto_and_unique(self):
        import asyncio
        from transcriber import mcp_server
        calls = []
        orig, self.s.run = self.s.run, lambda *a, **kw: calls.append((a, kw)) or (_ for _ in ()).throw(RuntimeError("stop"))
        config.CONFIG.write_text(json.dumps({"watch_dir": str(self.tmp), "ai": {"provider": "openai", "model": "x"}}))
        try:
            with self.assertRaisesRegex(RuntimeError, "nur in der App per Klick"):
                asyncio.run(mcp_server.summarize_transcript(str(self.jp)))
            config.CONFIG.write_text(json.dumps({"watch_dir": str(self.tmp),
                                                 "ai": {"provider": "openai", "model": "x", "cloud_auto": True}}))
            shutil.copy(self.jp, self.tmp / "Zweites.transcript.json")
            with self.assertRaisesRegex(KeyError, "mehrere"):        # Suchbegriff trifft zwei: nicht raten
                asyncio.run(mcp_server.summarize_transcript("transcript"))
            with self.assertRaisesRegex(RuntimeError, "stop"):
                asyncio.run(mcp_server.summarize_transcript(str(self.jp)))
            self.assertTrue(calls[-1][1]["allow_cloud"])
        finally:
            self.s.run = orig

    def test_helpers(self):
        self.assertTrue(self.s.is_local("http://127.0.0.1:18085/v1"))
        self.assertFalse(self.s.is_local("https://api.openai.com/v1"))
        self.assertEqual(self.s.strip_thinking("a</think>\nText"), "Text")
        t, back = self.s.pseudonymize("Kim Beispiel sagt Kim. Kimberly bleibt.", self.doc)
        self.assertNotIn("Kim ", t); self.assertIn("Kimberly", t)
        self.assertEqual(self.s.restore(t, back), "Kim Beispiel sagt Kim. Kimberly bleibt.")


if __name__ == "__main__":
    unittest.main()
