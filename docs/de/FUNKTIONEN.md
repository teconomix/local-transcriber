# Funktionen

## Alles lokal

Aufnahme, Spracherkennung, Sprechererkennung, Stimmdatenbank und KI-Funktionen laufen auf dem Mac. Nach der
Installation braucht Transcriber kein Internet – außer du wählst für die KI-Auswertung ausdrücklich ein Cloud-Modell. Es gibt kein Konto, kein Abo, keine Telemetrie. Details:
[DATENSCHUTZ.md](DATENSCHUTZ.md).

## Aufnehmen

- **Ein Knopf** in der Menüleiste: „Aufnahme starten“, daneben die Mikrofonwahl.
- **Zwei Spuren:** Mikrofon (du und wer mit dir im Raum ist) und Systemton (die anderen im Call). Der Systemton wird
  per Core-Audio-Process-Tap abgegriffen – dafür reicht die Freigabe „Systemaudio“, keine Bildschirmaufnahme.
- **Apple-Sprachverarbeitung** fürs Mikrofon (Pegel, Rausch- und Echounterdrückung), abschaltbar; während Calls aus,
  damit die Call-App einen weiter hört.
- Aufnahmen landen unter `~/Transcriber/Aufnahmen/` (`Recordings` auf einem nicht deutschsprachigen Mac) und werden danach automatisch transkribiert.

## Transkribieren

- **Whisper large-v3-turbo** über MLX auf der GPU: ~50-fache Echtzeit (47 min Audio in ~1 min), dazu die
  Sprechererkennung mit ~28-facher Echtzeit.
- **Zwei Spracherkennungsmodelle:** Whisper turbo in 8 Bit (Standard, 0,9 GB) oder 16 Bit
  (1,6 GB) – gemessen gleich genau; 8 Bit braucht rund 0,8 GB weniger Arbeitsspeicher (auch beim Diktat). Wechseln
  unter Einstellungen › Aufnahme › Spracherkennung (lädt das Modell bei Bedarf), dort auch das nicht genutzte löschen.
  Das Update auf 0.11 stellt 16 Bit einmalig auf 8 Bit um; wer danach wieder 16 Bit wählt, behält es. Kommandozeile: `transcriber model [turbo|turbo-8bit] [--download] [--remove NAME]`.
- **Rund 100 Sprachen** (alle, die Whisper kennt). Zur Auswahl stehen anfangs Deutsch, Englisch, Spanisch und
  Französisch; weitere in den Einstellungen › Aufnahme › „Sprachen zur Auswahl“ an- oder abwählen. Am besten klappen
  weit verbreitete Sprachen, seltene deutlich schwächer. Ist eine Aufnahme eindeutig in einer anderen Sprache als
  eingestellt, gilt die erkannte.
- **Ausgabe** neben der Audiodatei: `<Name>.txt` (lesbar, mit Sprechern und Zeitmarken;
  Markdown `.md` wählbar in Einstellungen › Aufnahme), `<Name>.transcript.json`
  (vollständig, maschinenlesbar), optional `<Name>.srt` (Untertitel).
- **Löschen:** nur die Aufnahme (Transkript bleibt) oder alles samt den Stimmen aus diesem Gespräch; auf Wunsch
  alle transkribierten Audio- und Videodateien in `~/Transcriber` automatisch 30 Tage nach dem Transkript. Arbeitskopien gehen immer mit.
- **Glossar** für Namen und Fachbegriffe: feste Ersetzungen nach der Erkennung, in der App unter Einstellungen › Glossar
  (oder `transcriber vocab 'dG = DG, D.G.'`); nachträglich auf vorhandene Transkripte anwendbar.
- **Nachbessern:** Stellen, an denen Whisper ohne Satzzeichen weiterschreibt, werden einzeln neu erkannt und nur
  übernommen, wenn der Inhalt gleich bleibt; Wortschleifen („Happy Happy Happy …“) werden gekürzt.
- **Dateien transkribieren:** im Panel „Datei transkribieren …“ oder einfach in `~/Transcriber` legen
  (Ordnerwächter, optional). Video- und Audioformate, die ffmpeg lesen kann.

## Wer hat was gesagt

- **Sprechertrennung** mit pyannote community-1.
- **Stimmdatenbank:** Wen du einmal benennst, erkennt Transcriber in künftigen Aufnahmen wieder. Jede Bestätigung
  verbessert die Referenzen.
- **Ehrliche Unsicherheit:** Sicher zugeordnete Namen stehen ohne Zusatz, vermutete als „Name (?)“, unbekannte als
  „Sprecher A/B/…“. Die Schwellen hängen von der Sprechzeit ab (unter 15 s nie „sicher“).
- **Benennen im Panel:** ✓ übernimmt einen Vorschlag, ✎ öffnet das Namensfeld mit Vorschlägen aus der Stimmdatenbank
  und den Kalender-Teilnehmern.
- **Zwei Spuren:** Bei Calls trennt Transcriber „ich“ und „die anderen“ anhand der Spuren (im Test 100 %), auch wenn
  der Lautsprecher ins Mikrofon zurückhallt.

## Videokonferenzen

- **Automatische Erkennung:** Nutzt Teams, Zoom, FaceTime, Slack, Webex, Discord oder ein Browser (Meet, Teams im
  Browser) länger als 5 Sekunden das Mikrofon, fragt eine Mitteilung „Aufnehmen?“. Aufgenommen wird nur auf Klick.
- **Automatisches Ende:** Eine so gestartete Aufnahme endet 15 Sekunden nach dem Call und wird transkribiert.

## Kalender

- Läuft beim Start einer Aufnahme ein Termin, werden **Titel und Teilnehmer** gespeichert: Der Titel wird zum
  Dateinamen, die Teilnehmer werden beim Benennen vorgeschlagen und begrenzen die Zahl der gesuchten Sprecher.
- Eigene Termine haben Vorrang vor Terminen aus geteilten Kalendern. Welche Kalender zählen, stellst du in den
  Einstellungen ein.

## Sprechende Dateinamen

„2026-10-10 14-03 Budgetplanung Q4“ statt „Aufnahme 2026-10-10 14-03“ – aus dem Kalendertermin oder, wenn keiner
lief, per Apple Intelligence aus dem Inhalt (macOS 26). Transkript und Stimmdatenbank werden mitgezogen.

## Diktat überall

- **Rechte ⌘ halten, sprechen, loslassen:** Der Text erscheint an der Schreibmarke – in jeder App, auch im Terminal.
  10 Sekunden Diktat sind in ~0,2 Sekunden erkannt.
- **Startton** genau dann, wenn das Mikrofon wirklich aufnimmt; ein kleines Symbol an der Schreibmarke zeigt den
  Zustand (startet, nimmt auf, erkennt).
- **Rechte ⌥ = mit KI aufräumen** (macOS 26, Apple Intelligence, lokal): entfernt Füllwörter, setzt Satzzeichen,
  schreibt gesprochene Dateinamen richtig („dictate punkt py“ → `dictate.py`). Auf Wunsch liest es dazu den Text des
  aktiven Fensters, um Namen richtig zu schreiben. Weicht das Ergebnis zu stark ab, wird der Rohtext eingefügt.
- Tasten frei wählbar (rechte ⌘/⌥/⌃, fn). Die Zwischenablage bleibt erhalten.
- **Auch während einer Aufnahme** (Notizen im Call): Das Diktat nimmt den Mikrofonton der Aufnahme mit.

## Auswerten mit KI

- Nach dem Transkribieren macht ein Sprachmodell aus dem Gespräch ein **Protokoll** (Kernpunkte, Entscheidungen,
  Aufgaben, offene Fragen), eine **Kurzfassung**, einen **Auftrag nach dem 5-Punkte-Schema** (Operation Order, mit
  „Noch zu klären“), eine **Supervisions- und Coachingnotiz** (ohne Deutungen), **Kernaussagen mit Zitaten** oder eine
  **E-Mail zum Nachfassen**. Vorlagen sind bearbeitbar, eigene möglich.
- **Lokal** über Ollama, LM Studio, MTPLX oder jeden Server mit Schnittstelle nach OpenAI-Art – das Gespräch verlässt den
  Mac nicht. **Cloud** über OpenAI, Anthropic, Mistral, OpenRouter mit eigenem Schlüssel: nur auf Klick (Automatik nur
  ausdrücklich), Namen vorher durch Platzhalter ersetzt (abschaltbar).
- **Lokaler Server bei Bedarf:** Mit Startbefehl (z. B. `ollama serve`) startet Transcriber den Server, wenn er
  gebraucht wird, und beendet ihn nach einstellbarer Zeit ohne Nutzung bzw. beim Beenden der App wieder.
- Per Klick oder automatisch nach jeder Transkription; Ergebnis als `<Name>.summary.md` neben dem Transkript, im Panel
  die ersten Kernpunkte und Aufgaben. Neue Sprechernamen ziehen in die Zusammenfassung nach.
- **Weiterarbeiten** in Claude, Claude Code oder Codex mit einem Klick (die App öffnet sich mit vorbereitetem Text,
  abgeschickt wird nichts). Im **Obsidian-Plugin** erscheint die Zusammenfassung als eigener Abschnitt mit abhakbaren
  Aufgaben.

## Für Profis

- **Kommandozeile:** `transcriber transcribe DATEI`, `who`, `name`, `confirm`, `speakers`, `vocab`, `rename`, `summarize`, `watch`.
- **MCP-Server** (`transcriber-mcp`): Werkzeuge `transcribe`, `who`, `name_speaker`, `confirm_speakers`,
  `list_speakers`, `show_glossary`, `add_to_glossary`, `apply_glossary`, `recent_transcripts`, `read_transcript`,
  `get_summary`, `list_templates`, `summarize_transcript` für KI-Agenten wie Claude; dazu jede Vorlage als Prompt (in
  Claude Desktop z. B. `/protokoll`), die der Agent mit seinem eigenen Modell anwendet – z. B. „da steht
  Kali statt KI, merk dir das“ trägt die Schreibweise ins Glossar ein und korrigiert das aktuelle Transkript.
- **Ordnerwächter** als LaunchAgent: legt Ergebnisse neben jede neue Datei in `~/Transcriber` und seinen Unterordnern –
  außer im Aufnahmeordner der App, dort startet die App selbst. Eine im Finder umbenannte oder verschobene Datei behält
  ihr Transkript (am Inhalt erkannt), statt neu transkribiert zu werden.
- **Einstellungen** in `~/.local/share/transcriber/config.json` (Schwellen, Formate, Sprecherzahl …).
