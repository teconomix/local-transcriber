# Datenschutz

**Kurz:** Transcriber verarbeitet alles auf deinem Mac. Es sendet keine Audiodaten, Transkripte, Stimmen, Kalender-
oder Bildschirminhalte irgendwohin. Es gibt keine Telemetrie, keine Analyse, kein Konto.

## Was lokal gespeichert wird

| Daten | Ort | Hinweis |
|---|---|---|
| Aufnahmen, Transkripte | `~/Transcriber/` | deine Dateien |
| **Stimmdatenbank** | `~/.local/share/transcriber/speakers.db` | **biometrische Daten** (Stimm-Einbettungen) der benannten Personen; nur für dich lesbar (Dateirechte 0600) |
| Termin zur Aufnahme | `<Aufnahme>.event.json` neben der Aufnahme | Titel und Teilnehmer (Namen, E-Mail-Adressen) |
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

**Fehlerberichte** (Käfer im Panel) verschickt nicht die App: Sie legt eine ZIP-Datei in den Download-Ordner und
öffnet eine Mail an info@teconomix.net, die du selbst abschickst. Die Datei enthält Protokolle, Version, Mac-Modell,
macOS, Freigaben, Audiogeräte und Einstellungen der App – keine Aufnahmen, Transkripte, Stimmdatenbank oder Glossar.
Dateinamen, Termintitel, Namen und E-Mail-Adressen werden durch Platzhalter ersetzt, sofern du das nicht abschaltest.

## Personen, die du aufnimmst

Wer Gespräche aufnimmt und Stimmen speichert, verarbeitet personenbezogene – bei Stimmprofilen sogar biometrische –
Daten anderer. Hol die Einwilligung der Beteiligten ein, bevor du aufnimmst und Stimmen benennst. Einzelne Personen
und ihre Stimmreferenzen entfernst du im Fenster **Stimmen …** oder mit `transcriber speakers forget NAME`.
Löschst du eine Aufnahme mit „Alles löschen“, gehen auch die Stimmen aus diesem Gespräch.
