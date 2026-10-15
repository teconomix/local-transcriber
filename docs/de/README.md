# Local Transcriber

**Meetings, Calls und Diktate – transkribiert auf deinem Mac. Ohne Cloud.**

English: [README.md](../../README.md)

Local Transcriber (in der Menüleiste kurz „Transcriber“) ist ein kleines Menüleisten-Werkzeug für macOS: Es nimmt Gespräche auf, schreibt sie mit, erkennt,
wer gesprochen hat, und lässt dich überall per Tastendruck diktieren. Alles läuft lokal auf dem Mac – kein Konto,
kein Abo, kein Lizenzserver, kein Audio, das den Rechner verlässt.

```bash
curl -fsSL https://transcriber.teconomix.net/install.sh | bash
```

Oder mit Homebrew: `brew install --cask teconomix/tap/local-transcriber`. Fragen: [Diskussionen](https://github.com/teconomix/local-transcriber/discussions).

## Was es kann

- **Meetings aufnehmen** – ein Klick; Mikrofon und Systemton (die anderen im Call) als getrennte Spuren.
- **Transkribieren** – Whisper large-v3-turbo auf der Apple-Silicon-GPU (MLX): eine Stunde Audio samt Sprechererkennung in rund drei bis vier Minuten.
- **Sprecher erkennen** – pyannote mit lernender Stimmdatenbank; einmal benannt, beim nächsten Mal erkannt.
- **Videokonferenzen** – erkennt Teams, Zoom, Meet & Co., bietet die Aufnahme an und beendet sie mit dem Call.
- **Kalender** – Termintitel als Dateiname, Teilnehmer als Vorschläge beim Benennen.
- **Diktat überall** – Taste halten, sprechen, loslassen: Text steht an der Schreibmarke jeder App.
- **Lokale KI** (macOS 26) – Diktat aufräumen, sprechende Dateinamen – mit Apple Intelligence auf dem Gerät.
- **Für Profis** – Ordnerwächter, Markdown/JSON/SRT, Glossar, Kommandozeile, MCP-Server für KI-Agenten.

Ausführlich: [FUNKTIONEN.md](FUNKTIONEN.md) · Bedienung: [ANLEITUNG.md](ANLEITUNG.md) ·
Installation: [INSTALLATION.md](INSTALLATION.md) · Datenschutz: [DATENSCHUTZ.md](DATENSCHUTZ.md)

## Voraussetzungen

Mac mit Apple Silicon (M1 oder neuer), macOS 14 Sonoma oder neuer (KI-Funktionen: macOS 26 mit Apple Intelligence),
ca. 8 GB freier Speicher, 16 GB Arbeitsspeicher empfohlen. Internet nur für die Installation.

## Aufbau

| Teil | Ort | Technik |
|---|---|---|
| Menüleisten-App | `app/` | Swift/SwiftUI, AVFoundation, Core-Audio-Process-Tap, EventKit, Foundation Models, Vision |
| Kern | `transcriber/` | Python: mlx-whisper, pyannote.audio, ffmpeg, SQLite (Stimmdatenbank) |
| Kommandozeile / MCP | `transcriber/cli.py`, `transcriber/mcp_server.py` | `transcriber transcribe …`, MCP-Werkzeuge |
| Installer | `installer/` | `install.sh`, `uninstall.sh` |
| Release | `scripts/make-release.sh` | baut `dist/<Version>/` |
| Website | `website/` | statisch |

Selbst bauen: siehe [ENTWICKLUNG.md](ENTWICKLUNG.md).

## Rechtliches

Freie Software unter der [MIT-Lizenz](../../LICENSE) – **ohne jede Gewähr**. Verwendete Modelle und Bibliotheken behalten
ihre eigenen Lizenzen: [THIRD_PARTY_NOTICES.md](../../THIRD_PARTY_NOTICES.md).

**Aufnahmen:** Du bist selbst dafür verantwortlich, die Einwilligung aller Beteiligten einzuholen. Das heimliche
Aufzeichnen von Gesprächen ist in vielen Ländern verboten.
