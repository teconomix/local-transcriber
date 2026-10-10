"""Sprecherdatenbank (SQLite, lokal, nicht synchronisiert – enthält biometrische Stimmeinbettungen).

Je Person beliebig viele Einbettungen (eine je bestätigter Aufnahme). Abgleich: Kosinus-Ähnlichkeit eines
Clusters zum sprechzeitgewichteten Mittel der Referenzen einer Person."""
import sqlite3
import time
import unicodedata

import numpy as np

from . import config

SCHEMA = """
CREATE TABLE IF NOT EXISTS persons(id INTEGER PRIMARY KEY, name TEXT UNIQUE NOT NULL, created REAL);
CREATE TABLE IF NOT EXISTS embeddings(id INTEGER PRIMARY KEY, person_id INTEGER NOT NULL REFERENCES persons(id),
  vec BLOB NOT NULL, speech_s REAL, job_id TEXT, label TEXT, source TEXT, origin TEXT, created REAL,
  UNIQUE(job_id, label));
CREATE TABLE IF NOT EXISTS jobs(id TEXT PRIMARY KEY, source TEXT, transcript TEXT, model TEXT, created REAL);
CREATE TABLE IF NOT EXISTS clusters(job_id TEXT NOT NULL, label TEXT NOT NULL, vec BLOB NOT NULL, speech_s REAL,
  person_id INTEGER, score REAL, status TEXT, PRIMARY KEY(job_id, label));
"""


def connect():
    config.DATA.mkdir(parents=True, exist_ok=True)
    db = sqlite3.connect(config.DB)
    db.row_factory = sqlite3.Row
    db.executescript(SCHEMA)
    config.DB.chmod(0o600)
    return db


def _vec(b):
    return np.frombuffer(b, dtype=np.float32)


def _unit(v):
    v = np.asarray(v, dtype=np.float32)
    return v / (np.linalg.norm(v) + 1e-9)


def norm_name(name):
    """Einheitliche Schreibweise: macOS liefert Umlaute aus der App zerlegt (NFD), sonst entstehen Doppelgänger."""
    return unicodedata.normalize("NFC", name).strip()


def resolve_name(db, name):
    """Vorname allein → voller Name, wenn genau eine Person so heißt. Nötig, seit Personen mit Nachnamen geführt
    werden (2026-10-10): ältere Transkripte und kurze Eingaben sagen noch „Kim“ – ohne das entstünde eine zweite
    Person neben „Kim Beispiel“."""
    name = norm_name(name)
    if db.execute("SELECT 1 FROM persons WHERE name=?", (name,)).fetchone() or " " in name:
        return name
    hits = [r["name"] for r in db.execute("SELECT name FROM persons") if r["name"].lower().startswith(name.lower() + " ")]
    return hits[0] if len(hits) == 1 else name


def person_id(db, name, create=True):
    name = resolve_name(db, name)
    r = db.execute("SELECT id FROM persons WHERE name=?", (name,)).fetchone()
    if r:
        return r["id"]
    if not create:
        raise KeyError(f"unbekannte Person {name!r}")
    return db.execute("INSERT INTO persons(name, created) VALUES(?,?)", (name, time.time())).lastrowid


def centroids(db):
    """{person_id: (name, unit-centroid, n_refs, total_speech_s)}"""
    out = {}
    for p in db.execute("SELECT id, name FROM persons"):
        rows = db.execute("SELECT vec, speech_s FROM embeddings WHERE person_id=?", (p["id"],)).fetchall()
        if not rows:
            continue
        V = np.stack([_unit(_vec(r["vec"])) for r in rows])
        w = np.array([max(r["speech_s"] or 1, 1) for r in rows])
        out[p["id"]] = (p["name"], _unit((V * w[:, None]).sum(0)), len(rows), float(w.sum()))
    return out


def sure_match(score, speech_s, cfg):
    """Gestuft nach Sprechzeit (bench/short_speech_test.py, 2026-10-10, 553 Stücke, eine Aufnahme ausgelassen):
    falsche Person höchstens 0,69 bei 5 s, 0,67 bei 10 s, 0,62 bei 20 s, 0,48 bei 60 s – nie ≥ 0,75.
    < 15 s: nie sicher · 15–60 s: ab 0,75 · ab 60 s: ab 0,65."""
    if speech_s < cfg["min_sure_s"]:
        return False
    return score >= (cfg["match_sure"] if speech_s >= cfg["min_speech_s"] else cfg["match_sure_short"])


def identify(db, clusters, cfg=None):
    """Ordnet Cluster bekannten Personen zu. Ergänzt je Cluster: person_id, name, score, second, status
    (sicher | vermutlich | unbekannt). Zwei Cluster dürfen nur dann dieselbe Person bekommen, wenn beide über der
    Sicher-Schwelle liegen (pyannote spaltet eine Stimme gelegentlich auf; verschiedene Personen lagen gemessen ≤ 0,45)."""
    cfg = cfg or config.load()
    C = centroids(db)
    cand = []
    for c in clusters:
        e = _unit(c["embedding"])
        sims = sorted(((float(e @ cv), pid) for pid, (_, cv, _, _) in C.items()), reverse=True)
        c["candidates"] = [(C[pid][0], round(s, 3)) for s, pid in sims[:3]]
        for s, pid in sims:
            cand.append((s, c["label"], pid))
        c.update(person_id=None, name=None, score=None, status="unbekannt")
    by = {c["label"]: c for c in clusters}
    taken = {}
    for s, label, pid in sorted(cand, reverse=True):
        c = by[label]
        if c["person_id"] is not None or s < cfg["match_maybe"]:
            continue
        strong = s >= cfg["match_sure"]
        sure = sure_match(s, c["speech_s"], cfg)
        if pid in taken and not (strong and taken[pid]):
            continue
        c.update(person_id=pid, name=C[pid][0], score=round(s, 3), status="sicher" if sure else "vermutlich")
        taken[pid] = taken.get(pid, True) and strong
    return clusters


def save_job(db, job_id, source, transcript, model, clusters):
    db.execute("INSERT OR REPLACE INTO jobs VALUES(?,?,?,?,?)", (job_id, str(source), str(transcript), model, time.time()))
    for c in clusters:
        db.execute("INSERT OR REPLACE INTO clusters VALUES(?,?,?,?,?,?,?)",
                   (job_id, c["label"], _unit(c["embedding"]).tobytes(), c["speech_s"], c.get("person_id"),
                    c.get("score"), c.get("status")))
    db.commit()


def enroll(db, job_id, label, name, origin="named", cfg=None):
    """Cluster einer Aufnahme einer Person zuweisen und (bei genug Sprechzeit) als Referenz speichern."""
    cfg = cfg or config.load()
    c = db.execute("SELECT * FROM clusters WHERE job_id=? AND label=?", (job_id, label)).fetchone()
    if not c:
        raise KeyError(f"Cluster {label} in Auftrag {job_id} nicht gefunden")
    pid = person_id(db, name)
    db.execute("UPDATE clusters SET person_id=?, status='bestätigt' WHERE job_id=? AND label=?", (pid, job_id, label))
    src = db.execute("SELECT source FROM jobs WHERE id=?", (job_id,)).fetchone()
    stored = False
    if (c["speech_s"] or 0) >= cfg["min_enroll_s"]:
        db.execute("INSERT OR REPLACE INTO embeddings(person_id, vec, speech_s, job_id, label, source, origin, created) "
                   "VALUES(?,?,?,?,?,?,?,?)", (pid, c["vec"], c["speech_s"], job_id, label, src and src["source"], origin, time.time()))
        stored = True
    db.commit()
    return stored


def persons(db):
    rows = db.execute("""SELECT p.id, p.name, COUNT(e.id) n, COALESCE(SUM(e.speech_s),0) s FROM persons p
                         LEFT JOIN embeddings e ON e.person_id=p.id GROUP BY p.id ORDER BY p.name""").fetchall()
    return [dict(r) for r in rows]


def consistency(db):
    """Je Person: Ähnlichkeit jeder Referenz zum Mittel der übrigen (niedrige Werte = vermutlich falsch zugeordnet)."""
    out = {}
    for p in db.execute("SELECT id, name FROM persons"):
        rows = db.execute("SELECT id, vec, speech_s, source, label, origin, created FROM embeddings WHERE person_id=? "
                          "ORDER BY created", (p["id"],)).fetchall()
        V = [_unit(_vec(r["vec"])) for r in rows]
        res = []
        for i, r in enumerate(rows):
            rest = [v for j, v in enumerate(V) if j != i]
            res.append({"id": r["id"], "source": r["source"], "label": r["label"], "speech_s": r["speech_s"],
                        "origin": r["origin"], "created": r["created"],
                        "sim_to_rest": round(float(V[i] @ _unit(np.mean(rest, 0))), 3) if rest else None})
        out[p["name"]] = res
    return out


def drop_ref(db, ref_id):
    """Eine einzelne Stimmreferenz entfernen (z. B. falsch bestätigt). Die Person bleibt."""
    n = db.execute("DELETE FROM embeddings WHERE id=?", (int(ref_id),)).rowcount
    db.commit()
    if not n:
        raise KeyError(f"Referenz #{ref_id} nicht gefunden")


def rename(db, old, new):
    db.execute("UPDATE persons SET name=? WHERE name=?", (norm_name(new), norm_name(old))); db.commit()


def merge(db, src, dst):
    a, b = person_id(db, src, create=False), person_id(db, dst)
    db.execute("UPDATE embeddings SET person_id=? WHERE person_id=?", (b, a))
    db.execute("UPDATE clusters SET person_id=? WHERE person_id=?", (b, a))
    db.execute("DELETE FROM persons WHERE id=?", (a,)); db.commit()


def forget(db, name):
    """Person samt aller Stimmreferenzen entfernen (Cluster-Zuordnungen werden gelöst)."""
    pid = person_id(db, name, create=False)
    db.execute("DELETE FROM embeddings WHERE person_id=?", (pid,))
    db.execute("UPDATE clusters SET person_id=NULL, status='unbekannt' WHERE person_id=?", (pid,))
    db.execute("DELETE FROM persons WHERE id=?", (pid,)); db.commit()
