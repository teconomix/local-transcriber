# Anleitung

## Das Panel

Klick auf das Wellen-Symbol in der Menüleiste öffnet das Panel:

1. **Aufnahme starten** – daneben das Mikrofon. Während der Aufnahme: Zeit, Pegel, „Aufnahme beenden“.
2. **Datei transkribieren …** – daneben die Sprache (gilt für Aufnahmen, Dateien und Diktat; welche zur Auswahl stehen, legst du in den Einstellungen fest).
3. **Diktat-Zeile** – zeigt, welche Tasten belegt sind; orange/rot, wenn eine Freigabe fehlt.
4. **Transkriptionen** – die letzten Aufträge mit Fortschritt, „Öffnen“, „Im Finder“ und den erkannten Sprechern.
5. Unten: Ordner öffnen · Stimmen … · Einstellungen … (⌘,) · Beenden.

## Ein Meeting aufnehmen

1. Mikrofon wählen (meist „Systemstandard“), **Aufnahme starten**.
2. Beim ersten Mal fragt macOS nach **Mikrofon** und **Systemaudio** – erlauben.
3. **Aufnahme beenden.** Transcriber transkribiert und benennt die Datei; eine Mitteilung meldet „Transkript fertig“.
4. **Öffnen** zeigt das Transkript (Markdown).

## Eine Videokonferenz aufnehmen

Einfach den Call starten. Nach ein paar Sekunden erscheint „Call in Teams erkannt – Aufnehmen?“ → **Aufnehmen**.
Nach dem Auflegen endet die Aufnahme von selbst. Alternativ wie oben per Knopf.

Tipp: Mit Kopfhörern ist die Trennung zwischen dir und den anderen am saubersten; über Lautsprecher funktioniert es
ebenfalls.

## Sprecher benennen

Unter jedem fertigen Transkript stehen die erkannten Sprecher:

- **Name** – sicher erkannt.
- **Name (?)** – vermutlich; **✓ übernehmen** bestätigt.
- **Sprecher A** – unbekannt; **✎** öffnet das Namensfeld. Darunter stehen Vorschläge (bekannte Stimmen 👤, Kalender-
  Teilnehmer 📅). Klick auf einen Vorschlag benennt sofort.
- **Alle Zuordnungen übernehmen** bestätigt alles auf einmal.

Jede Benennung verbessert die Erkennung künftiger Aufnahmen. Das Fenster **Stimmen …** zeigt die Stimmdatenbank und
erlaubt, einzelne Referenzen oder Personen zu entfernen. Gib Personen am besten **Vor- und Nachnamen**.

## Diktieren

1. **Einstellungen › Diktat** einschalten. macOS fragt nach **Bedienungshilfen** – erlauben (nötig, um die Taste zu
   erkennen und den Text einzufügen).
2. In ein beliebiges Textfeld klicken, **rechte ⌘ halten**, auf den Ton warten, sprechen, loslassen.
3. Mit **rechter ⌥** statt ⌘ räumt Apple Intelligence den Text auf (macOS 26).

Hinweis: Auf der deutschen Tastatur tippt die rechte ⌥ auch `@` und `€`. Das wird als Tastenkürzel erkannt und
ignoriert; wer den kurzen Startton dabei stört, wählt in den Einstellungen die rechte ⌃.

## Dateien transkribieren

- **Datei transkribieren …** im Panel, oder
- Datei in `~/Transkription` legen, wenn der Ordnerwächter aktiv ist – das Ergebnis erscheint daneben.

## Einstellungen

| Reiter | Inhalt |
|---|---|
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
- **Diktat reagiert nicht:** Bedienungshilfen-Freigabe prüfen; nach einem Update ggf. Eintrag entfernen und neu
  erlauben.
- **Kein Ton der anderen im Call:** Freigabe „Systemaudio“ prüfen.
- **Transkription fehlgeschlagen:** Fehlermeldung im Panel; `transcriber transcribe DATEI` im Terminal zeigt Details.
