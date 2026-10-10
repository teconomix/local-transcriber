"""Schnelle Tests des Python-Kerns – ohne Modelle, ohne Netz, ohne echte Daten (`scripts/check.sh`).

Alles läuft in einem frischen TRANSCRIBER_DATA-Verzeichnis; die echte Stimmdatenbank wird nie berührt.
Sollergebnisse der Markdown-Ausgabe: tests/fixtures/beispiel.{de,en}.md. Ändert sich die Ausgabe absichtlich:
`UPDATE_GOLDEN=1 scripts/check.sh`, dann die Unterschiede im Diff prüfen."""
import json
import os
import shutil
import sys
import tempfile
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
        self.assertTrue((tmp / "beispiel.md").exists())


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
        for ext in (".md", ".srt"):
            (tmp / f"{old}{ext}").write_text("alt")
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


class VoiceDatabase(unittest.TestCase):
    def test_sure_thresholds_by_speaking_time(self):
        cfg = config.load()
        cases = [(0.99, 14, False), (0.74, 30, False), (0.75, 30, True), (0.64, 60, False), (0.65, 60, True),
                 (0.65, 59, False)]
        for score, secs, want in cases:
            self.assertEqual(speakers.sure_match(score, secs, cfg), want, (score, secs))

    def test_first_name_resolves_to_single_person(self):
        db = fresh_db()
        speakers.person_id(db, "Kim Beispiel")
        self.assertEqual(speakers.resolve_name(db, "Kim"), "Kim Beispiel")
        speakers.person_id(db, "Kim Anders")
        self.assertEqual(speakers.resolve_name(db, "Kim"), "Kim")          # zwei Kims: nicht raten

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


if __name__ == "__main__":
    unittest.main()
