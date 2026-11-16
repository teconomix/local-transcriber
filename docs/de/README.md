# Local Transcriber

**Meetings, Calls und Diktate – transkribiert auf deinem Mac. Ohne Cloud.**

English: [README.md](../../README.md)

Local Transcriber (in der Menüleiste kurz „Transcriber“) ist ein kleines Menüleisten-Werkzeug für macOS: Es nimmt Gespräche auf, schreibt sie mit, erkennt,
wer gesprochen hat, und lässt dich überall per Tastendruck diktieren. Alles läuft lokal auf dem Mac – kein Konto,
kein Abo, kein Lizenzserver, kein Audio, das den Rechner verlässt.

[![Demo-Video (80 s) auf der Website](https://transcriber.teconomix.net/assets/video/poster-de.jpg)](https://transcriber.teconomix.net/de/?k=github)

```bash
curl -fsSL https://transcriber.teconomix.net/k/github/install.sh | bash
```

Oder mit Homebrew (Updates dann mit `brew upgrade`):

```bash
brew install --cask teconomix/tap/local-transcriber
```

Apple Silicon, macOS 14 oder neuer. Fragen: [Diskussionen](https://github.com/teconomix/local-transcriber/discussions).

## Was es kann

- **Meetings aufnehmen** – ein Klick; Mikrofon und Systemton (die anderen im Call) als getrennte Spuren.
- **Transkribieren** – Whisper large-v3-turbo auf der Apple-Silicon-GPU (MLX): eine Stunde Audio samt Sprechererkennung in rund drei bis vier Minuten.
- **Sprecher erkennen** – pyannote mit lernender Stimmdatenbank; einmal benannt, beim nächsten Mal erkannt.
- **Videokonferenzen** – erkennt Teams, Zoom, Meet & Co., bietet die Aufnahme an und beendet sie mit dem Call.
- **Kalender** – Termintitel als Dateiname, Teilnehmer als Vorschläge beim Benennen.
- **Diktat überall** – Taste halten, sprechen, loslassen: Text steht an der Schreibmarke jeder App.
- **Auswerten mit KI** – Protokoll mit Aufgaben, Kurzfassung, Auftrag im 5-Punkte-Schema und mehr, mit lokalem Modell
  (Ollama, LM Studio, MTPLX) oder einem Cloud-Anbieter deiner Wahl – nur auf Klick, Namen durch Platzhalter ersetzt.
- **Lokale KI** (macOS 26) – Diktat aufräumen, sprechende Dateinamen – mit Apple Intelligence auf dem Gerät.
- **Für Profis** – Ordnerwächter, Text oder Markdown, JSON, SRT, Glossar, Kommandozeile, MCP-Server für KI-Agenten.

Ausführlich: [FUNKTIONEN.md](FUNKTIONEN.md) · Bedienung: [ANLEITUNG.md](ANLEITUNG.md) · Arbeitsablauf: [ARBEITSABLAUF.md](ARBEITSABLAUF.md) ·
Installation: [INSTALLATION.md](INSTALLATION.md) · Datenschutz: [DATENSCHUTZ.md](DATENSCHUTZ.md)

## So sieht ein Transkript aus

Reiner Text neben der Aufnahme (auf Wunsch Markdown, JSON und SRT). Beispiel mit einem ausgedachten Gespräch, im echten
Ausgabeformat:

```text
2026-11-12 Projektstart

Quelle: 2026-11-12 Projektstart.m4a · 47:23 min · 2 Tonspur(en)
Erstellt: 2026-11-12 10:47 · Modell: whisper-large-v3-turbo · Sprecher: pyannote community-1

Sprecher:
  Ich – 17:00 min – sicher (0.86)
  Alex – 16:20 min – bestätigt
  Sprecher C – 10:10 min – unbekannt

[00:00:03] Ich: Danke, dass ihr Zeit habt. Fangen wir mit dem Zeitplan an?

[00:00:09] Alex: Ja. Der Entwurf steht, die Prüfung dauert bis Freitag.

[00:00:16] Ich: Gut, dann bleibt der Start am 20.

[00:00:21] Sprecher C: Ich schicke die Folien heute an alle.
```

„Sprecher C“ einmal benennen, dann wird die Stimme in den nächsten Aufnahmen erkannt. Wie alles zusammenspielt, von der
Aufnahme bis zur KI-Zusammenfassung: [Arbeitsablauf](https://transcriber.teconomix.net/de/arbeitsablauf.html?k=gh-example).

## Anleitungen

- [Interviews transkribieren](https://transcriber.teconomix.net/de/interviews-transkribieren.html?k=gh-guides) – Forschung und Journalismus, mit Zeitstempeln
- [Sprechererkennung am Mac](https://transcriber.teconomix.net/de/sprechererkennung-mac.html?k=gh-guides) – Sprecher offline trennen, benannte Stimmen wiedererkennen
- [Diktieren am Mac](https://transcriber.teconomix.net/de/diktieren-mac.html?k=gh-guides) – Taste halten, sprechen, Text steht an der Schreibmarke
- [Beratung und Supervision](https://transcriber.teconomix.net/de/beratung.html?k=gh-guides) – vertrauliche Gespräche bleiben auf dem Mac
- [Transkripte in Obsidian](https://transcriber.teconomix.net/de/obsidian-transkripte.html?k=gh-guides) – Aufnahmen werden Notizen in deiner Vault

## Voraussetzungen

Mac mit Apple Silicon (M1 oder neuer), macOS 14 Sonoma oder neuer (KI-Funktionen: macOS 26 mit Apple Intelligence),
ca. 8 GB freier Speicher, 16 GB Arbeitsspeicher empfohlen. Internet nur für die Installation (und für ein
Cloud-Modell, falls du eines wählst). Für die lokale KI-Auswertung: ein lokales Sprachmodell, z. B. in Ollama oder LM Studio.

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
