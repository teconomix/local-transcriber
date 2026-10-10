# Datenschutz

**Kurz:** Transcriber verarbeitet alles auf deinem Mac. Es sendet keine Audiodaten, Transkripte, Stimmen, Kalender-
oder Bildschirminhalte irgendwohin. Es gibt keine Telemetrie, keine Analyse, kein Konto.

## Was lokal gespeichert wird

| Daten | Ort | Hinweis |
|---|---|---|
| Aufnahmen, Transkripte | `~/Transkription/` | deine Dateien |
| **Stimmdatenbank** | `~/.local/share/transcriber/speakers.db` | **biometrische Daten** (Stimm-Einbettungen) der benannten Personen; nur für dich lesbar (Dateirechte 0600) |
| Termin zur Aufnahme | `<Aufnahme>.event.json` neben der Aufnahme | Titel und Teilnehmer (Namen, E-Mail-Adressen) |
| Protokolle | `~/.local/share/transcriber/*.log` | technische Meldungen, keine Inhalte von Diktaten |

## Was nicht gespeichert wird

- **Diktate:** Audio bleibt nur im Arbeitsspeicher und wird nach der Erkennung verworfen.
- **Bildschirmtext** (nur „Diktat mit KI“, optional): wird im Arbeitsspeicher erkannt, an das lokale Apple-Modell
  gegeben und verworfen.

## Netzwerk

Nur der **Installer** lädt Dateien: Release-Dateien von transcriber.teconomix.net, uv/Python von astral.sh,
Python-Pakete von PyPI, das Whisper-Modell von Hugging Face und ggf. ffmpeg von ffmpeg.martin-riedl.de. Im Betrieb
greift Transcriber nicht aufs Internet zu (die Spracherkennung läuft mit `HF_HUB_OFFLINE=1`).

## Personen, die du aufnimmst

Wer Gespräche aufnimmt und Stimmen speichert, verarbeitet personenbezogene – bei Stimmprofilen sogar biometrische –
Daten anderer. Hol die Einwilligung der Beteiligten ein, bevor du aufnimmst und Stimmen benennst. Einzelne Personen
und ihre Stimmreferenzen entfernst du im Fenster **Stimmen …** oder mit `transcriber speakers forget NAME`.
