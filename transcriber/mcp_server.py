"""MCP-Server für Claude Code (stdio). Die Transkription läuft als eigener Prozess (`transcriber transcribe`),
damit die Modelle nach jedem Auftrag wieder aus dem Speicher verschwinden."""
import asyncio
import json
import sys
from pathlib import Path

from mcp.server import MCPServer
from mcp.server.mcpserver import Context
from mcp.types import ToolAnnotations

from . import pipeline, speakers
from .i18n import t

# Beschreibungen für Sprachmodelle: nur Englisch. Ergebnisse folgen der Ausgabesprache (i18n).
mcp = MCPServer("transcriber", instructions=(
    "Local transcription (German, English and many other languages) with speaker recognition on this Mac. The result "
    "is written next to the audio file: <name>.txt or <name>.md (readable, setting text_format) and <name>.transcript.json. Speakers are addressed by "
    "letter (A, B, …) or display name. Name unknown voices with name_speaker; this improves recognition of future "
    "recordings."))

# Hinweise für Clients (MCP ToolAnnotations): rein lesende Werkzeuge kann ein Client ohne Rückfrage nutzen, verändernde
# gezielt bestätigen lassen. Alles läuft lokal (open_world false). transcribe ersetzt ein früheres Transkript derselben
# Datei (destructive); ob ein zweiter Lauf die Stimmdatenbank exakt gleich hinterlässt, ist nicht zugesichert → kein
# idempotent-Hinweis. name_speaker ersetzt die bisherige Zuordnung; confirm_speakers ergänzt nur.
READ = ToolAnnotations(read_only_hint=True, open_world_hint=False)


@mcp.tool(title="Transcribe audio", annotations=ToolAnnotations(read_only_hint=False, destructive_hint=True, open_world_hint=False))
async def transcribe(path: str, ctx: Context, language: str | None = None,
                     num_speakers: int | None = None, srt: bool = False) -> str:
    """Transcribe an audio or video file (readable transcript – .txt by default, .md if configured – plus JSON next to
    the file, optionally SRT).
    language: Whisper language code, e.g. de (default), en, es, fr. Model: Whisper large-v3-turbo, glossary from
    `transcriber vocab`. Pass num_speakers only if known for sure. If a transcription is already running, the job waits.
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

    await asyncio.gather(read_progress(), read_result(), p.wait())
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


def main():
    mcp.run()


if __name__ == "__main__":
    main()
