# Installation

## Voraussetzungen

- Mac mit **Apple Silicon** (M1 oder neuer) – Intel-Macs werden nicht unterstützt (MLX).
- **macOS 14 Sonoma** oder neuer. KI-Funktionen (Diktat aufräumen, sprechende Dateinamen per KI) brauchen
  **macOS 26 mit eingeschalteter Apple Intelligence**.
- ca. **8 GB** freier Speicher (Spracherkennungsmodell ~3 GB, Python-Umgebung ~2 GB).
- 16 GB Arbeitsspeicher empfohlen.
- Internet nur während der Installation. Keine Administratorrechte nötig.

## Installieren

Terminal öffnen (Programme › Dienstprogramme › Terminal) und einfügen:

```bash
curl -fsSL https://transcriber.teconomix.net/install.sh | bash
```

Der Installer (dauert je nach Leitung 5–15 Minuten):

1. prüft Mac, macOS-Version und Speicherplatz,
2. lädt die Release-Dateien und prüft ihre Prüfsummen,
3. richtet eine eigene Python-Umgebung ein (uv, Python 3.12, Pakete aus PyPI),
4. nutzt ein vorhandenes ffmpeg oder lädt einen statischen Build,
5. installiert das Sprechererkennungsmodell (mitgeliefert) und lädt das Whisper-Modell von Hugging Face,
6. legt die App nach `~/Applications/Transcriber.app` und die Kommandozeile nach `~/.local/bin/transcriber`,
7. bietet den Ordnerwächter für `~/Transcriber` an,
8. startet Transcriber.

Erneut ausführen = aktualisieren. Stimmdatenbank, Einstellungen und Transkripte bleiben erhalten. Beim Update von 0.5
oder älter benennt der Installer den Datenordner `~/Transkription` einmalig in `~/Transcriber` um (nichts wird kopiert).

Optionen (hinter `bash -s --` anhängen, z. B. `curl -fsSL …/install.sh | bash -s -- --no-watch`):
`--no-launch` (App nicht starten), `--no-watch` (keinen Ordnerwächter anbieten), `--yes` (keine Rückfragen).

### Mit Homebrew

```bash
brew install --cask teconomix/tap/local-transcriber
```

Der Cask führt denselben Installer aus (`--yes --no-watch`); `brew upgrade` aktualisiert, `brew uninstall
local-transcriber` ruft den Deinstaller auf (ohne Rückfrage im Terminal bleiben Stimmdatenbank und Whisper-Modell
liegen). Den Ordnerwächter bietet dieser Weg nicht an – bei Bedarf einmal den curl-Installer ausführen und mit „j“
antworten; Updates lassen ihn weiterlaufen.

Fragen oder hängt etwas? [Diskussionen auf GitHub](https://github.com/teconomix/local-transcriber/discussions).

## Erste Schritte

Beim ersten Aufnehmen fragt macOS nach **Mikrofon** und **Systemaudio**. Fürs Diktat in den Einstellungen das Diktat
einschalten und **Bedienungshilfen** erlauben. Übersicht aller Freigaben: [ANLEITUNG.md](ANLEITUNG.md#freigaben-im-überblick).

## Was wo liegt

| Pfad | Inhalt |
|---|---|
| `~/Applications/Transcriber.app` | App |
| `~/.local/share/transcriber/` | Python-Umgebung, ffmpeg, Sprechererkennungsmodell, **Stimmdatenbank** (`speakers.db`), Protokolle |
| `~/.cache/huggingface/hub/` | Whisper-Modell |
| `~/Transcriber/` | Aufnahmen und Transkripte (deine Daten) |
| `~/Library/LaunchAgents/net.teconomix.transcriber.watch.plist` | Ordnerwächter (optional) |

## Deinstallieren

```bash
bash ~/.local/share/transcriber/uninstall.sh
```

Entfernt App, Programmdaten und Ordnerwächter. Fragt, ob Stimmdatenbank und Whisper-Modell gelöscht werden sollen.
**Aufnahmen und Transkripte unter `~/Transcriber` bleiben immer erhalten.**

## Hinweis zur Signatur

Die App ist (noch) nicht von Apple notarisiert. Weil der Installer sie per `curl` lädt, prüft macOS sie nicht über
Gatekeeper, und sie startet ohne Warnung. Wer die App-Datei stattdessen im Browser herunterlädt, muss sie beim ersten
Start mit Rechtsklick › Öffnen bestätigen.
