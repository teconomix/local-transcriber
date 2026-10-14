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
3. **Diktat-Zeile** – zeigt, welche Tasten belegt sind; orange/rot, wenn eine Freigabe fehlt. Der Schalter rechts
   schaltet das Diktat ein oder aus (aus = Tasten und der Speicher des Diktat-Dienstes sind wieder frei).
4. **Transkriptionen** – die letzten Aufträge mit Fortschritt, den erkannten Sprechern und *Öffnen · Im Finder ·
   Umbenennen · Neu auswerten …*. *Neu auswerten …* bietet **Namen neu zuordnen** (nur neuer Abgleich mit der
   Stimmdatenbank, in einer Sekunde) und **Sprecher neu trennen** mit Automatisch oder 1–10 Personen (wenn zwei Personen
   vermischt oder eine aufgeteilt wurde).
5. Unten: **Ordner** · **Einstellungen** (⌘,) · Käfer (Fehler melden) · **Beenden**.

## Ein Meeting aufnehmen

1. Mikrofon wählen (meist „Systemstandard“), **Aufnahme starten**.
2. Beim ersten Mal fragt macOS nach **Mikrofon** und **Systemaudio** – erlauben.
3. **Aufnahme beenden.** Transcriber transkribiert und benennt die Datei; eine Mitteilung meldet „Transkript fertig“.
4. **Öffnen** zeigt das Transkript (Markdown).

## Eine Videokonferenz aufnehmen

Einfach den Call starten. Nach ein paar Sekunden erscheint „Call in Teams erkannt – Aufnehmen?“ → **Aufnehmen**.
Nach dem Auflegen endet die Aufnahme von selbst. Alternativ **Call aufnehmen** im Panel.

Call-Aufnahmen nehmen das **Mikrofon, das die Call-App benutzt**, und ziehen nach, wenn du es im Call wechselst (das
Panel zeigt „Mikrofon wie im Call: …“; ein Wechsel kostet bis zu einer Sekunde Ton). Den Ton der anderen nimmt
Transcriber unabhängig davon auf, ob er über Lautsprecher oder Kopfhörer läuft. Andere Mikrofone als der
Systemstandard werden ohne Apples Sprachverarbeitung aufgenommen.

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

Hinweis: Auf der deutschen Tastatur tippt die rechte ⌥ auch `@` und `€`. Das wird als Tastenkürzel erkannt und
ignoriert; wer den kurzen Startton dabei stört, wählt in den Einstellungen die rechte ⌃.

## Dateien transkribieren

- **Datei transkribieren …** im Panel, oder
- Datei in `~/Transcriber` legen, wenn der Ordnerwächter aktiv ist – das Ergebnis erscheint daneben. Der Ordner
  `Aufnahmen` gehört der App: Aufnahmen dort transkribiert die App; fehlt einer das Transkript (z. B. „Transkribieren“
  war aus), bietet das Panel es an.
- **Umbenennen** einer Aufnahme im Panel; im Finder umbenannt oder verschoben, zieht der Wächter das Transkript nach.

## Einstellungen

| Reiter | Inhalt |
|---|---|
| Allgemein | Version, Datenordner, einmal täglich nach Updates suchen (optional) |
| Aufnahme | Systemton mitschneiden, Sprachverarbeitung, nach der Aufnahme transkribieren/benennen, Calls erkennen, Sprachen zur Auswahl |
| Diktat | ein/aus, Tasten (wörtlich / mit KI), Bildschirmtext als Kontext, Ton, Symbol, Sprachverarbeitung |
| Kalender | Termine nutzen, Auswahl der Kalender |

## Glossar

Namen und Fachbegriffe, die oft falsch erkannt werden, als feste Ersetzung eintragen:

```bash
transcriber vocab 'Claude Code = Cloud-Code, Cloud Code'
```

Links der gewünschte Begriff, rechts die Schreibweisen, die ersetzt werden sollen.

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
