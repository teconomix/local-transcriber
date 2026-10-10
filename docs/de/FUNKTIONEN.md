# Funktionen

## Alles lokal

Aufnahme, Spracherkennung, Sprechererkennung, Stimmdatenbank und KI-Funktionen laufen auf dem Mac. Nach der
Installation braucht Transcriber kein Internet. Es gibt kein Konto, kein Abo, keine Telemetrie. Details:
[DATENSCHUTZ.md](DATENSCHUTZ.md).

## Aufnehmen

- **Ein Knopf** in der Menüleiste: „Aufnahme starten“, daneben die Mikrofonwahl.
- **Zwei Spuren:** Mikrofon (du und wer mit dir im Raum ist) und Systemton (die anderen im Call). Der Systemton wird
  per Core-Audio-Process-Tap abgegriffen – dafür reicht die Freigabe „Systemaudio“, keine Bildschirmaufnahme.
- **Apple-Sprachverarbeitung** fürs Mikrofon (Pegel, Rausch- und Echounterdrückung), abschaltbar.
- Aufnahmen landen unter `~/Transkription/Aufnahmen/` und werden danach automatisch transkribiert.

## Transkribieren

- **Whisper large-v3-turbo** über MLX auf der GPU: ~50-fache Echtzeit (47 min Audio in ~1 min), dazu die
  Sprechererkennung mit ~28-facher Echtzeit.
- **Rund 100 Sprachen** (alle, die Whisper kennt). Zur Auswahl stehen anfangs Deutsch, Englisch, Spanisch und
  Französisch; weitere in den Einstellungen › Aufnahme › „Sprachen zur Auswahl“ an- oder abwählen. Am besten klappen
  weit verbreitete Sprachen, seltene deutlich schwächer.
- **Ausgabe** neben der Audiodatei: `<Name>.md` (lesbar, mit Sprechern und Zeitmarken), `<Name>.transcript.json`
  (vollständig, maschinenlesbar), optional `<Name>.srt` (Untertitel).
- **Glossar** für Namen und Fachbegriffe: feste Ersetzungen nach der Erkennung (`transcriber vocab 'dG = DG, D.G.'`).
- **Dateien transkribieren:** im Panel „Datei transkribieren …“ oder einfach in `~/Transkription` legen
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

## Für Profis

- **Kommandozeile:** `transcriber transcribe DATEI`, `who`, `name`, `confirm`, `speakers`, `vocab`, `rename`, `watch`.
- **MCP-Server** (`transcriber-mcp`): Werkzeuge `transcribe`, `who`, `name_speaker`, `confirm_speakers`,
  `list_speakers` für KI-Agenten wie Claude.
- **Ordnerwächter** als LaunchAgent: legt Ergebnisse neben jede neue Datei in `~/Transkription`.
- **Einstellungen** in `~/.local/share/transcriber/config.json` (Schwellen, Formate, Sprecherzahl …).
