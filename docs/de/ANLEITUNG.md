# Anleitung

## Sprache

Transcriber folgt der Sprache von macOS und gibt es auf Deutsch und Englisch (andere macOS-Sprachen bekommen Englisch). Soll nur Transcriber eine andere
Sprache nutzen: **Systemeinstellungen › Allgemein › Sprache & Region › Apps**.

## Das Panel

Klick auf das Wellen-Symbol in der Menüleiste öffnet das Panel:

1. **Aufnahme starten** – daneben das Mikrofon. Während der Aufnahme: Zeit, Pegel, „Aufnahme beenden“. Läuft ein
   erkannter Call, heißt der Knopf **Call aufnehmen** und nimmt das Mikrofon, das die Call-App benutzt (siehe unten).
2. **Datei transkribieren …** – daneben die Sprache (gilt für Aufnahmen, Dateien und Diktat; welche zur Auswahl stehen,
   legst du in den Einstellungen fest) und die **Personenzahl** (Auto oder genau 1–6 – nur für die nächste Aufnahme/Datei).
   Die Sprache gilt beim Beenden der Aufnahme. Ist eindeutig eine andere Sprache zu hören (z. B. vergessen
   zurückzustellen), nimmt Transcriber die erkannte und vermerkt das im Kopf des Transkripts.
3. **Diktat-Zeile** – zeigt, welche Tasten belegt sind; orange/rot, wenn eine Freigabe fehlt. Der Schalter rechts
   schaltet das Diktat ein oder aus (aus = Tasten und der Speicher des Diktat-Dienstes sind wieder frei).
4. **Transkriptionen** – die letzten Aufträge mit Fortschritt, den erkannten Sprechern und *Öffnen · Im Finder ·
   Neu auswerten · Zusammenfassen*. Den **Titel anklicken** benennt Aufnahme und Transkript um (Enter übernimmt,
   Escape bricht ab). *Neu auswerten* bietet **Namen neu zuordnen** (nur neuer Abgleich mit der
   Stimmdatenbank, in einer Sekunde) und **Sprecher neu trennen** mit Automatisch oder 1–10 Personen (wenn zwei Personen
   vermischt oder eine aufgeteilt wurde).
5. Unten: **Ordner** · **Einstellungen** (⌘,) · Käfer (Fehler melden) · **Beenden**.

## Ein Meeting aufnehmen

1. Mikrofon wählen (meist „Systemstandard“), **Aufnahme starten**.
2. Beim ersten Mal fragt macOS nach **Mikrofon** und **Systemaudio** – erlauben.
3. **Aufnahme beenden.** Transcriber transkribiert und benennt die Datei; eine Mitteilung meldet „Transkript fertig“.
4. **Öffnen** zeigt das Transkript – als reiner Text (`.txt`, Standard) oder Markdown (`.md`), siehe Einstellungen › Aufnahme › „Transkript speichern als“.

## Eine Videokonferenz aufnehmen

Einfach den Call starten. Nach ein paar Sekunden erscheint „Call in Teams erkannt – Aufnehmen?“ → **Aufnehmen**.
Nach dem Auflegen endet die Aufnahme von selbst. Alternativ **Call aufnehmen** im Panel.

Call-Aufnahmen nehmen das **Mikrofon, das die Call-App benutzt**, und ziehen nach, wenn du es im Call wechselst (das
Panel zeigt „Mikrofon wie im Call: …“; ein Wechsel kostet bis zu einer Sekunde Ton). Den Ton der anderen nimmt
Transcriber unabhängig davon auf, ob er über Lautsprecher oder Kopfhörer läuft. Während eines Calls nimmt Transcriber
das Mikrofon immer ohne Apples Sprachverarbeitung auf – sonst hört dich z. B. in Zoom niemand mehr (die Call-App
unterdrückt Rauschen und Echo selbst).

Verschwindet die Mitteilung zu schnell: *Systemeinstellungen › Mitteilungen › Transcriber › Mitteilungsstil: Hinweise*
– dann bleibt sie stehen, bis du klickst.

Tipp: Mit Kopfhörern ist die Trennung zwischen dir und den anderen am saubersten; über Lautsprecher funktioniert es
ebenfalls.

## Sprecher benennen

Unter jedem fertigen Transkript stehen die erkannten Sprecher:

- **Name** – sicher erkannt.
- **Name (?)** – vermutlich; **✓ übernehmen** bestätigt.
- **Sprecher A** – unbekannt; **✎** öffnet das Namensfeld. Darunter stehen Vorschläge (bekannte Stimmen 👤, Kalender-
  Teilnehmer 📅). Klick auf einen Vorschlag benennt sofort.
- **Alle Zuordnungen übernehmen** bestätigt alles auf einmal.

Jede Benennung verbessert die Erkennung künftiger Aufnahmen. *Einstellungen › Stimmen* zeigt die Stimmdatenbank und
erlaubt, einzelne Referenzen oder Personen zu entfernen. Gib Personen am besten **Vor- und Nachnamen**.

**Stimmen weitergeben:** *Einstellungen › Stimmen › Exportieren …* schreibt je ausgewählter Person einen Stimmabdruck (256 Zahlen
und den Namen – keine Aufnahmen, Titel oder Pfade) in eine `.voices.json`-Datei; *Importieren …* auf einem anderen
Mac lässt auswählen, wer übernommen wird. Stimmabdrücke sind biometrische Daten: nur mit Einwilligung der Personen
weitergeben. Die Datei ist nicht verschlüsselt. Vor dem Import die eigene Stimme benennen – sonst kann sie einer
ähnlich klingenden Kollegin zugeordnet werden.

## Diktieren

1. Mit dem Schalter im Panel oder unter **Einstellungen › Diktat** einschalten. macOS fragt nach **Bedienungshilfen** – erlauben (nötig, um die Taste zu
   erkennen und den Text einzufügen).
2. In ein beliebiges Textfeld klicken, **rechte ⌘ halten**, auf den Ton warten, sprechen, loslassen.
3. Mit **rechter ⌥** statt ⌘ räumt Apple Intelligence den Text auf (macOS 26).

Diktieren geht auch, während eine Aufnahme läuft, z. B. Notizen im Call: Die anderen hören dich wie sonst, und was du
diktierst, steht auch im Transkript.

Hinweis: Auf der deutschen Tastatur tippt die rechte ⌥ auch `@` und `€`. Das wird als Tastenkürzel erkannt und
ignoriert; wer den kurzen Startton dabei stört, wählt in den Einstellungen die rechte ⌃.

## Dateien transkribieren

- **Datei transkribieren …** im Panel, oder
- Datei in `~/Transcriber` legen, wenn der Ordnerwächter aktiv ist – das Ergebnis erscheint daneben. Der Ordner
  `Aufnahmen` gehört der App: Aufnahmen dort transkribiert die App; fehlt einer das Transkript (z. B. „Transkribieren“
  war aus), bietet das Panel es an.
- **Umbenennen:** im Panel den Titel anklicken; im Finder umbenannt oder verschoben, zieht der Wächter das Transkript nach.

## Zusammenfassen mit KI

Ein Sprachmodell macht aus einem fertigen Transkript ein Protokoll, eine Kurzfassung oder was die Vorlage verlangt.

1. **Einstellungen › KI:** Anbieter wählen – lokal **Ollama**, **LM Studio**, **MTPLX** oder eine **eigene Adresse**
   (jeder Server mit Schnittstelle nach OpenAI-Art), in der Cloud **OpenAI**, **Anthropic**, **Mistral** oder
   **OpenRouter** mit eigenem Schlüssel (liegt im Schlüsselbund). Modell eintragen oder nach **Verbindung testen** aus
   der Liste wählen.
2. Im Panel unter einem Transkript **Zusammenfassen** → Vorlage wählen. Ergebnis: `<Name>.summary.md` neben dem
   Transkript; der Eintrag zeigt die ersten Kernpunkte und Aufgaben mit **Öffnen · Kopieren · Teilen · ⋯**. **Teilen**
   öffnet das macOS-Menü (Mail mit Betreff und formatiertem Text, Nachrichten, Notizen …); im ⋯-Menü: andere Vorlage, neu
   erzeugen, als Datei teilen, **Weiterarbeiten in** Claude, Claude Code oder Codex, löschen.
3. Auf Wunsch **nach jeder Transkription automatisch** (Einstellungen › KI) – mit einem Cloud-Anbieter nur, wenn du
   „Cloud-Modelle nur auf Klick“ ausschaltest.

Mitgeliefert: **Protokoll**, **Kurzfassung**, **Auftrag (5-Punkte-Schema)**, **Supervisions- und Coachingnotiz**,
**Kernaussagen mit Zitaten**, **E-Mail zum Nachfassen**. Jede lässt sich bearbeiten (die eigene Fassung liegt unter
`~/.local/share/transcriber/prompts/`, „Zurücksetzen“ holt die mitgelieferte zurück) oder als neue Vorlage anlegen;
der Stern markiert die Vorlage der Automatik. Platzhalter: `{{title}}`, `{{date}}`, `{{participants}}`, `{{event}}`,
`{{language}}`, `{{transcript}}`.

Benennst du danach Sprecher, stehen die neuen Namen auch in der Zusammenfassung. Bei Cloud-Anbietern ersetzt
Transcriber Namen vorher durch Platzhalter (abschaltbar). Kommandozeile: `transcriber summarize DATEI [--template ID]`,
`transcriber summarize --templates`, `transcriber summarize --models` (Verbindungstest).

Tempo (gemessen auf einem MacBook Pro M5 Pro, 64 GB): ein 25-Minuten-Gespräch in 30–40 s, 54 Minuten in rund einer
Minute, über drei Stunden (49 000 Tokens) in vier Minuten mit Qwen3.8-27B über MTPLX. Bei sehr langen Gesprächen
übersehen kleinere oder schnellere Modelle eher Einzelheiten aus der Mitte – im Test entging Qwen3.5-35B-A3B (Ollama)
eine von drei eingestreuten Aufgaben.

## Löschen

Das **Papierkorb-Symbol** neben einem Eintrag im Panel fragt, wie viel weg soll:

- **Nur Aufnahme:** Das Audio kommt in den Papierkorb; Transkript, Stimmen und Eintrag bleiben („Aufnahme gelöscht“).
  „Namen neu zuordnen“ geht weiter, „Sprecher neu trennen“ nicht mehr.
- **Alles löschen:** Audio, Transkript und Termin kommen in den Papierkorb; die Stimmen aus diesem Gespräch werden
  endgültig gelöscht.

Transcriber löscht dabei auch seine Arbeitskopien des Audios (in `~/.local/share/transcriber/cache/`). Im Finder
gelöscht, räumt Transcriber innerhalb weniger Minuten genauso auf. Eine Notiz in Obsidian löschst du dort selbst.
**Einstellungen › Aufnahme › „Aufnahmen nach 30 Tagen löschen“** macht „Nur Aufnahme“ automatisch für transkribierte
Aufnahmen im Aufnahmeordner. Kommandozeile: `transcriber delete DATEI [--audio-only]`.

## Einstellungen

Die Bereiche stehen links im Fenster.

| Bereich | Inhalt |
|---|---|
| Allgemein | Version, Datenordner, bei Anmeldung starten, einmal täglich nach Updates suchen (optional); gibt es eine neue Version, legt „Update-Befehl kopieren“ den passenden Befehl in die Zwischenablage – im Terminal einfügen und Return drücken |
| Aufnahme | Systemton mitschneiden, Sprachverarbeitung, nach der Aufnahme transkribieren/benennen, Calls erkennen, Sprachen zur Auswahl |
| Diktat | ein/aus, Tasten (wörtlich / mit KI), Bildschirmtext als Kontext, Ton, Symbol, Sprachverarbeitung |
| Kalender | Termine nutzen, Auswahl der Kalender |
| Glossar | Namen und Fachbegriffe mit falschen Schreibweisen (siehe unten) |
| KI | Zusammenfassung: Automatik, Vorlage, Anbieter, Modell, Schlüssel, Datenschutz, Vorlagen bearbeiten (siehe oben) |
| Stimmen | gespeicherte Stimmen ansehen, entfernen, exportieren, importieren |

## Glossar

Namen und Fachbegriffe, die oft falsch erkannt werden, als feste Ersetzung eintragen – in der App unter
**Einstellungen › Glossar** (links die richtige Schreibweise, rechts, wie die Erkennung sie schreibt) oder im Terminal:

```bash
transcriber vocab 'Claude Code = Cloud-Code, Cloud Code'
```

Ersetzt wird nach der Erkennung, auch in Wörtern mit Bindestrich („Kali-Strategie“ → „KI-Strategie“). Das gilt für
neue Transkripte und das Diktat. Für ein vorhandenes Transkript: **Neu auswerten › Glossar anwenden** (bzw.
`transcriber vocab --apply DATEI.transcript.json`) – ohne neu zu rechnen. Vorsicht bei echten Wörtern als
Schreibweise: Sie werden überall ersetzt.

## Freigaben im Überblick

| Freigabe | wofür | nötig? |
|---|---|---|
| Mikrofon | Aufnahme, Diktat | ja |
| Systemaudio („Nur Systemaudio aufnehmen“) | Ton der anderen im Call | für Calls |
| Mitteilungen | „Transkript fertig“, „Call erkannt“ | empfohlen |
| Bedienungshilfen | Diktat: Taste erkennen, Text einfügen | nur fürs Diktat |
| Kalender (Vollzugriff) | Termintitel und Teilnehmer | optional |
| Bildschirmaufnahme | Diktat mit KI: Text des aktiven Fensters als Kontext | optional |

Alle Freigaben lassen sich in **Systemeinstellungen › Datenschutz & Sicherheit** jederzeit widerrufen.

## Probleme

- **Protokolle:** `~/.local/share/transcriber/app.log` (App), `dictate.log` (Diktat), `watch.log` (Ordnerwächter).
- **Fehler melden:** Käfer unten im Panel (oder *Fehler melden …* bei einer fehlgeschlagenen Transkription) –
  beschreiben, was passiert ist; Protokolle und Systeminfos hängen an einer fertigen Mail (keine Aufnahmen, Transkripte).
- **Diktat reagiert nicht:** Bedienungshilfen-Freigabe prüfen; nach einem Update ggf. Eintrag entfernen und neu
  erlauben.
- **Kein Ton der anderen im Call:** Freigabe „Systemaudio“ prüfen.
- **Transkription fehlgeschlagen:** Fehlermeldung im Panel; `transcriber transcribe DATEI` im Terminal zeigt Details.
