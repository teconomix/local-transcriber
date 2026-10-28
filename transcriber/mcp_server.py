"""MCP-Server für Claude Code (stdio). Die Transkription läuft als eigener Prozess (`transcriber transcribe`),
damit die Modelle nach jedem Auftrag wieder aus dem Speicher verschwinden."""
import asyncio
import contextlib
import json
import signal
import sys
from pathlib import Path

from mcp.server import MCPServer
from mcp.server.mcpserver import Context
from mcp.types import ToolAnnotations

from . import config, glossary, pipeline, speakers, summarize
from .i18n import t

# Beschreibungen für Sprachmodelle: nur Englisch. Ergebnisse folgen der Ausgabesprache (i18n).
mcp = MCPServer("transcriber", instructions=(
    "Local transcription (German, English and many other languages) with speaker recognition on this Mac. The result "
    "is written next to the audio file: <name>.txt or <name>.md (readable, setting text_format) and <name>.transcript.json. Speakers are addressed by "
    "letter (A, B, …) or display name. Name unknown voices with name_speaker; this improves recognition of future "
    "recordings. If a name or term is misrecognized, add it with add_to_glossary (future transcripts) and fix the "
    "current one with apply_glossary. Find conversations with recent_transcripts, read them with read_transcript. "
    "summarize_transcript writes <name>.summary.md with the language model configured in the app (Settings › AI); "
    "the prompts of this server are the same templates for you to apply yourself."))

# Hinweise für Clients (MCP ToolAnnotations): rein lesende Werkzeuge kann ein Client ohne Rückfrage nutzen, verändernde
# gezielt bestätigen lassen. Alles läuft lokal (open_world false). transcribe ersetzt ein früheres Transkript derselben
# Datei (destructive); ob ein zweiter Lauf die Stimmdatenbank exakt gleich hinterlässt, ist nicht zugesichert → kein
# idempotent-Hinweis. name_speaker ersetzt die bisherige Zuordnung; confirm_speakers ergänzt nur. add_to_glossary
# ergänzt nur; apply_glossary schreibt das Transkript neu (wiederholt: 0 Ersetzungen).
READ = ToolAnnotations(read_only_hint=True, open_world_hint=False)


@mcp.tool(title="Transcribe audio", annotations=ToolAnnotations(read_only_hint=False, destructive_hint=True, open_world_hint=False))
async def transcribe(path: str, ctx: Context, language: str | None = None,
                     num_speakers: int | None = None, srt: bool = False) -> str:
    """Transcribe an audio or video file (readable transcript – .txt by default, .md if configured – plus JSON next to
    the file, optionally SRT).
    language: Whisper language code, e.g. de (default), en, es, fr. Model: Whisper large-v3-turbo as set in the app
    (8-bit by default), glossary from `transcriber vocab`. Pass num_speakers only if known for sure. If a transcription is already running, the job waits.
    Takes about 1/30 of the recording length plus speaker separation."""
    exe = Path(sys.executable).with_name("transcriber")
    args = [str(exe), "transcribe", str(Path(path).expanduser()), "--progress", "json"]
    if language:
        args += ["--language", language]
    if num_speakers:
        args += ["--speakers", str(num_speakers)]
    if srt:
        args.append("--srt")
    p = await asyncio.create_subprocess_exec(*args, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
    result, errors = None, []

    async def read_progress():
        async for line in p.stderr:
            try:
                ev = json.loads(line)
                await ctx.report_progress(ev["progress"], 1.0, ev["message"])
            except (ValueError, KeyError):
                errors.append(line.decode(errors="replace").rstrip())

    async def read_result():
        nonlocal result
        async for line in p.stdout:
            try:
                result = json.loads(line).get("result")
            except ValueError:
                pass

    try:
        await asyncio.gather(read_progress(), read_result(), p.wait())
    finally:
        # Abgebrochen (Client-Timeout/Cancel): Kindprozess beenden, sonst rechnet er weiter und hält run.lock. Erst SIGINT –
        # dann räumt pipeline.run <name>.lock und die Statusdatei auf –, nach 10 s hart.
        def stop(sig):
            if p.returncode is None:
                with contextlib.suppress(ProcessLookupError):
                    p.send_signal(sig)
        if p.returncode is None:
            stop(signal.SIGINT)
            asyncio.get_running_loop().call_later(10, stop, signal.SIGKILL)
    if p.returncode or not result:
        return t("Fehlgeschlagen:", "Failed:") + "\n" + "\n".join(errors[-15:])
    doc, _ = pipeline.load_doc(result["json"])
    return json.dumps({"files": result, "duration_min": round(doc["duration"] / 60, 1), "model": doc["model"],
                       "speakers": _speakers(doc)}, ensure_ascii=False, indent=1)


def _speakers(doc):
    return [{"letter": c["letter"], "display": c["display"], "status": c["status"], "score": c.get("score"),
             "speech_min": round(c["speech_s"] / 60, 1), "candidates": c.get("candidates")}
            for c in sorted(doc["speakers"], key=lambda c: -c["speech_s"])]


@mcp.tool(title="Who is who", annotations=READ)
def who(transcript: str, speaker: str | None = None) -> str:
    """Who is who in a transcript: status (sicher = sure, vermutlich = probably, unbekannt = unknown,
    bestätigt = confirmed), similarity score, candidates."""
    doc, _ = pipeline.load_doc(transcript)
    cs = _speakers(doc)
    if speaker:
        c = pipeline.find_cluster(doc, speaker)
        cs = [x for x in cs if x["letter"] == c["letter"]]
    return json.dumps(cs, ensure_ascii=False, indent=1)


@mcp.tool(title="Name a speaker", annotations=ToolAnnotations(
    read_only_hint=False, destructive_hint=True, idempotent_hint=True, open_world_hint=False))
def name_speaker(transcript: str, speaker: str, name: str) -> str:
    """Name a speaker (letter or display name) in a transcript. The voice is stored as a reference for that person
    and the transcript is rewritten."""
    paths, stored, c = pipeline.name_speaker(transcript, speaker, name)
    return f"{c['letter']} = {name}; " + (t("Stimmreferenz gespeichert", "voice reference stored") if stored else
                                          t("Stimmreferenz nicht gespeichert (zu kurz)", "voice reference not stored (too short)")) \
        + f"; {paths.get('md')}"


@mcp.tool(title="Confirm speaker matches", annotations=ToolAnnotations(
    read_only_hint=False, destructive_hint=False, idempotent_hint=True, open_world_hint=False))
def confirm_speakers(transcript: str) -> str:
    """Confirm all automatic speaker matches of a transcript as correct (improves the voice references)."""
    return t("bestätigt: ", "confirmed: ") + (", ".join(pipeline.confirm(transcript)) or t("nichts", "nothing"))


@mcp.tool(title="List known speakers", annotations=READ)
def list_speakers() -> str:
    """Known persons with number of voice references and total reference speaking time."""
    return json.dumps(speakers.persons(speakers.connect()), ensure_ascii=False, indent=1)


def _vocab():
    return Path(config.load()["vocab_file"]).expanduser()


@mcp.tool(title="Show glossary", annotations=READ)
def show_glossary() -> str:
    """The glossary: correct spellings of names and terms, each with the misrecognized spellings that are replaced after
    speech recognition (also in transcripts and dictation)."""
    return json.dumps(glossary.entries(_vocab()), ensure_ascii=False, indent=1)


@mcp.tool(title="Add to glossary", annotations=ToolAnnotations(
    read_only_hint=False, destructive_hint=False, idempotent_hint=True, open_world_hint=False))
def add_to_glossary(term: str, misrecognized: list[str]) -> str:
    """Add a correct spelling (term) with the wrong spellings speech recognition produced, e.g. term "KI",
    misrecognized ["Kali"]. An existing term only gets the new spellings. Replacement is by whole word (also inside
    hyphenated words) and everywhere – do not list ordinary words that also occur correctly. Affects future
    transcripts; for an existing one call apply_glossary."""
    entry, changed = glossary.add(_vocab(), term, misrecognized)
    return json.dumps({"entry": entry, "changed": changed}, ensure_ascii=False)


@mcp.tool(title="Apply glossary to a transcript", annotations=ToolAnnotations(
    read_only_hint=False, destructive_hint=True, idempotent_hint=True, open_world_hint=False))
def apply_glossary(transcript: str) -> str:
    """Apply the current glossary to a finished transcript (no recomputation); the readable transcript is rewritten.
    Returns the number of replacements."""
    n = pipeline.apply_glossary(transcript)
    return t(f"{n} Ersetzungen", f"{n} replacements")


def _recent(limit=10, query=None):
    """Transkripte unter dem Datenordner, jüngste zuerst; query sucht in Dateiname, Termin und Sprechernamen."""
    root = Path(config.load()["watch_dir"]).expanduser()
    files = sorted(root.rglob("*.transcript.json"), key=lambda f: f.stat().st_mtime, reverse=True) if root.exists() else []
    out, q = [], (query or "").strip().lower()
    for f in files:
        try:
            doc = json.loads(f.read_text())
        except (OSError, ValueError):
            continue
        names = [c["display"] for c in doc.get("speakers", [])]
        title = ((doc.get("event") or {}).get("title") or "")
        if q and q not in " ".join([f.name, title] + names).lower():
            continue
        sp = summarize.summary_path(f)
        out.append({"transcript": str(f), "title": f.name.removesuffix(".transcript.json"), "event": title or None,
                    "created": doc.get("created"), "duration_min": round(doc.get("duration", 0) / 60, 1),
                    "speakers": names, "summary": str(sp) if summarize.read_meta(sp) else None})
        if len(out) >= limit:
            break
    return out


def _resolve(transcript, unique=False):
    """Pfad oder Suchbegriff („“ = jüngstes Transkript) → Pfad des Transkripts. unique: Suchbegriff muss genau ein
    Transkript treffen (vor dem Senden in die Cloud nicht stillschweigend den jüngsten Treffer nehmen)."""
    if transcript and Path(transcript).expanduser().exists():
        return transcript
    hits = _recent(2 if unique else 1, transcript)
    if not hits:
        raise KeyError(t(f"kein Transkript zu {transcript!r} gefunden", f"no transcript found for {transcript!r}"))
    if unique and len(hits) > 1:
        raise KeyError(t(f"{transcript!r} trifft mehrere Transkripte – bitte den Pfad angeben (recent_transcripts)",
                         f"{transcript!r} matches several transcripts – pass the path (recent_transcripts)"))
    return hits[0]["transcript"]


@mcp.tool(title="Recent transcripts", annotations=READ)
def recent_transcripts(limit: int = 10, query: str | None = None) -> str:
    """Most recent transcripts (newest first) with title, calendar event, date, duration, speaker names and whether a
    summary exists. query filters by file name, event title or speaker name (e.g. a person's first name)."""
    return json.dumps(_recent(limit, query), ensure_ascii=False, indent=1)


@mcp.tool(title="Read a transcript", annotations=READ)
def read_transcript(transcript: str) -> str:
    """The conversation as readable text: one line per turn, "[hh:mm:ss] Speaker: text", plus a short header.
    transcript: path, or a search term as in recent_transcripts ("" = the newest)."""
    doc, jp = pipeline.load_doc(_resolve(transcript))
    c = summarize.context(doc)
    return (f"{c['title']} · {c['date']} · {round(doc['duration'] / 60)} min\n" + t("Sprecher", "Speakers")
            + f": {c['participants']}\n{c['event']}\n{jp}\n\n{c['transcript']}")


@mcp.tool(title="Read a summary", annotations=READ)
def get_summary(transcript: str) -> str:
    """The summary written by summarize (Markdown), if there is one. transcript: path or search term."""
    doc, jp = pipeline.load_doc(_resolve(transcript))
    sp = summarize.summary_path(jp)
    if not summarize.read_meta(sp):
        return t("Noch keine Zusammenfassung – mit summarize erzeugen.", "No summary yet – create one with summarize.")
    return sp.read_text(encoding="utf-8").split("\n", 1)[1]


@mcp.tool(title="Summary templates", annotations=READ)
def list_templates() -> str:
    """Templates for summarize (id, name, description). The same templates are offered as prompts of this server."""
    return json.dumps([{k: x[k] for k in ("id", "name", "description", "custom")} for x in summarize.templates().values()],
                      ensure_ascii=False, indent=1)


@mcp.tool(title="Summarize a transcript", annotations=ToolAnnotations(
    read_only_hint=False, destructive_hint=True, idempotent_hint=False, open_world_hint=True))
async def summarize_transcript(transcript: str, template: str | None = None) -> str:
    """Summarize a transcript with the language model configured in the app (Settings › AI; local or cloud) and write
    <name>.summary.md next to it (replaces an earlier summary). template: id from list_templates (default: the one set
    in the app). transcript: path or search term. Local models take about a minute for an hour of conversation.
    A cloud model is used only if the app allows it without a click (Settings › AI); the search term must then match
    exactly one transcript."""
    s = summarize.settings()
    cloud = not summarize.is_local(s["base_url"])
    if cloud and not s["cloud_auto"]:                    # wie die App ohne Klick: Cloud nur mit „cloud_auto“
        raise RuntimeError(t("Cloud-Modell nur in der App per Klick (Einstellungen › KI) – hier nicht erlaubt",
                             "cloud model only via click in the app (Settings › AI) – not allowed here"))
    out, meta = await asyncio.to_thread(summarize.run, _resolve(transcript, unique=cloud), template, allow_cloud=cloud)
    return (f"{out}\n{meta['name']} · {meta['model']} · {meta['seconds']} s\n\n"
            + out.read_text(encoding="utf-8").split("\n", 1)[1])


def _add_prompts():
    """Jede Vorlage auch als MCP-Prompt (in Claude Desktop z. B. als /protokoll): Der Client wendet sie mit seinem eigenen
    Modell an – der Weg „von der anderen Seite holen“, ohne dass hier ein Sprachmodell eingestellt sein muss."""
    from mcp.server.mcpserver.prompts.base import Prompt
    def make(tpl):
        def fn(transcript: str = "") -> str:
            doc, _ = pipeline.load_doc(_resolve(transcript))
            return summarize.SYSTEM + "\n\n" + summarize.fill(tpl["body"], summarize.context(doc))
        return fn
    for tpl in summarize.templates().values():
        fn = make(tpl)
        mcp.add_prompt(Prompt.from_function(fn, name=tpl["id"], title=tpl["name"], description=(
            tpl["description"] + " – transcript: path or search term (empty = newest)")))


_add_prompts()


def main():
    config.secure_data()
    mcp.run()


if __name__ == "__main__":
    main()

