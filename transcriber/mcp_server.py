"""MCP-Server für Claude Code (stdio). Die Transkription läuft als eigener Prozess (`transcriber transcribe`),
damit die Modelle nach jedem Auftrag wieder aus dem Speicher verschwinden."""
import asyncio
import json
import sys
from pathlib import Path

from mcp.server import MCPServer
from mcp.server.mcpserver import Context

from . import pipeline, speakers

mcp = MCPServer("transcriber", instructions=(
    "Lokale Transkription (Deutsch, Englisch und viele weitere Sprachen) mit Sprechererkennung auf diesem Mac. Ergebnis liegt neben der Audiodatei: "
    "<name>.md (lesbar) und <name>.transcript.json. Sprecher werden über Buchstaben (A, B, …) oder Anzeigenamen "
    "angesprochen. Unbekannte Stimmen mit name_speaker benennen; das verbessert die Erkennung künftiger Aufnahmen."))


@mcp.tool()
async def transcribe(path: str, ctx: Context, language: str | None = None,
                     num_speakers: int | None = None, srt: bool = False) -> str:
    """Audio- oder Videodatei transkribieren (Markdown + JSON neben der Datei, optional SRT).
    language: Whisper-Sprachcode, z. B. de (Standard), en, es, fr. Modell: Whisper large-v3-turbo, Glossar aus `transcriber vocab`.
    num_speakers nur, wenn sicher bekannt. Läuft schon eine Transkription, wartet der Auftrag.
    Dauert etwa 1/30 der Aufnahmelänge plus Sprechertrennung."""
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
        return "Fehlgeschlagen:\n" + "\n".join(errors[-15:])
    doc, _ = pipeline.load_doc(result["json"])
    return json.dumps({"files": result, "duration_min": round(doc["duration"] / 60, 1), "model": doc["model"],
                       "speakers": _speakers(doc)}, ensure_ascii=False, indent=1)


def _speakers(doc):
    return [{"letter": c["letter"], "display": c["display"], "status": c["status"], "score": c.get("score"),
             "speech_min": round(c["speech_s"] / 60, 1), "candidates": c.get("candidates")}
            for c in sorted(doc["speakers"], key=lambda c: -c["speech_s"])]


@mcp.tool()
def who(transcript: str, speaker: str | None = None) -> str:
    """Wer ist wer in einem Transkript: Status (sicher/vermutlich/unbekannt/bestätigt), Ähnlichkeit, Kandidaten."""
    doc, _ = pipeline.load_doc(transcript)
    cs = _speakers(doc)
    if speaker:
        c = pipeline.find_cluster(doc, speaker)
        cs = [x for x in cs if x["letter"] == c["letter"]]
    return json.dumps(cs, ensure_ascii=False, indent=1)


@mcp.tool()
def name_speaker(transcript: str, speaker: str, name: str) -> str:
    """Sprecher (Buchstabe oder Anzeigename) in einem Transkript benennen. Die Stimme wird als Referenz für die
    Person gespeichert und das Transkript neu geschrieben."""
    paths, stored, c = pipeline.name_speaker(transcript, speaker, name)
    return f"{c['letter']} = {name}; Stimmreferenz {'gespeichert' if stored else 'nicht gespeichert (zu kurz)'}; {paths.get('md')}"


@mcp.tool()
def confirm_speakers(transcript: str) -> str:
    """Alle automatischen Zuordnungen eines Transkripts als richtig bestätigen (verbessert die Referenzen)."""
    return "bestätigt: " + (", ".join(pipeline.confirm(transcript)) or "nichts")


@mcp.tool()
def list_speakers() -> str:
    """Bekannte Personen mit Anzahl Stimmreferenzen und gesamter Referenz-Sprechzeit."""
    return json.dumps(speakers.persons(speakers.connect()), ensure_ascii=False, indent=1)


def main():
    mcp.run()


if __name__ == "__main__":
    main()
