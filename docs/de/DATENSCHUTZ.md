# Datenschutz

**Kurz:** Transcriber verarbeitet alles auf deinem Mac. Es sendet keine Audiodaten, Transkripte, Stimmen, Kalender-
oder Bildschirminhalte irgendwohin – einzige Ausnahme: die KI-Auswertung mit einem Cloud-Anbieter, wenn du sie selbst
einrichtest (siehe Netzwerk). Es gibt keine Telemetrie, keine Analyse, kein Konto.

## Was lokal gespeichert wird

| Daten | Ort | Hinweis |
|---|---|---|
| Aufnahmen, Transkripte | `~/Transcriber/` | deine Dateien |
| **Stimmdatenbank** | `~/.local/share/transcriber/speakers.db` | **biometrische Daten** (Stimm-Einbettungen) der benannten Personen; nur für dich lesbar (Dateirechte 0600) |
| Termin zur Aufnahme | `<Aufnahme>.event.json` neben der Aufnahme | Titel und Teilnehmer (Namen, E-Mail-Adressen) |
| Zusammenfassung | `<Aufnahme>.summary.md` neben dem Transkript | nur, wenn du eine KI-Auswertung startest |
| KI-Einstellungen, eigene Vorlagen | `config.json` (Abschnitt `ai`), `prompts/` unter `~/.local/share/transcriber/` | Schlüssel für Cloud-Anbieter **nicht** dort, sondern im Schlüsselbund |
| Arbeitskopien | `~/.local/share/transcriber/cache/` | Audio als WAV und die Spracherkennung, fürs Neu-Auswerten; werden mit der Aufnahme gelöscht (Anleitung › Löschen) |
| Protokolle | `~/.local/share/transcriber/*.log` | technische Meldungen, keine Inhalte von Diktaten |

## Was nicht gespeichert wird

- **Diktate:** Audio bleibt nur im Arbeitsspeicher und wird nach der Erkennung verworfen.
- **Bildschirmtext** (nur „Diktat mit KI“, optional): wird im Arbeitsspeicher erkannt, an das lokale Apple-Modell
  gegeben und verworfen.

## Netzwerk

Nur der **Installer** lädt Dateien: Release-Dateien von transcriber.teconomix.net, uv/Python von astral.sh,
Python-Pakete von PyPI, das Whisper-Modell von Hugging Face und ggf. ffmpeg von ffmpeg.martin-riedl.de. Im Betrieb
greift Transcriber nicht aufs Internet zu (die Spracherkennung läuft mit `HF_HUB_OFFLINE=1`) – mit einer optionalen
Ausnahme: Wenn du zustimmst (das Panel fragt einmal; Einstellungen › Allgemein), liest die App einmal täglich
`https://transcriber.teconomix.net/latest.txt`, um auf eine neue Version hinzuweisen. Die Anfrage enthält nichts über
dich oder deine Aufnahmen; der Server sieht deine IP-Adresse und speichert sie nur gekürzt (z. B. 82.98.0.0) im Zugriffsprotokoll, das nach
7 Tagen gelöscht wird; aufbewahrt werden nur Tagessummen (siehe Datenschutzerklärung der Website).

**KI-Auswertung** (optional, Einstellungen › KI): Mit einem **lokalen** Modell (Ollama, LM Studio, MTPLX, eigener
Server auf `localhost`) bleibt alles auf dem Mac. Mit einem **Cloud-Anbieter** schickt Transcriber das Transkript samt
Titel, Datum und Teilnehmernamen mit deinem Schlüssel direkt an diesen Anbieter – standardmäßig nur auf Klick; Namen von
Sprechern und Termin-Teilnehmenden werden vorher durch Platzhalter ersetzt und in der Antwort wieder eingesetzt
(abschaltbar; andere persönliche Angaben im Gesprächsinhalt bleiben). Es gelten die Bestimmungen des Anbieters.

**Weiterarbeiten in Claude / Codex** öffnet das Programm mit vorbereitetem Text; abgeschickt wird erst, wenn du es dort tust.

**Fehlerberichte** (Käfer im Panel) verschickt nicht die App: Sie legt eine ZIP-Datei in ihren Datenordner
(`~/.local/share/transcriber/reports/`, nach 14 Tagen gelöscht) und
öffnet eine Mail an info@teconomix.net, die du selbst abschickst. Die Datei enthält Protokolle, Version, Mac-Modell,
macOS, Freigaben, Audiogeräte und Einstellungen der App – keine Aufnahmen, Transkripte, Stimmdatenbank oder Glossar.
Dateinamen, Termintitel, Namen und E-Mail-Adressen werden durch Platzhalter ersetzt, sofern du das nicht abschaltest.

## Personen, die du aufnimmst

Wer Gespräche aufnimmt und Stimmen speichert, verarbeitet personenbezogene – bei Stimmprofilen sogar biometrische –
Daten anderer. Hol die Einwilligung der Beteiligten ein, bevor du aufnimmst und Stimmen benennst. Einzelne Personen
und ihre Stimmreferenzen entfernst du im Fenster **Stimmen …** oder mit `transcriber speakers forget NAME`.
Löschst du eine Aufnahme mit „Alles löschen“, gehen auch die Stimmen aus diesem Gespräch.
