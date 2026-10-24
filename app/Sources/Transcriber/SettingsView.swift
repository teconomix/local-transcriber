import EventKit
import ServiceManagement
import SwiftUI

/// Einstellungen (eigenes Fenster): Allgemein · Aufnahme · Diktat · Kalender · Stimmen. Das Panel enthält nur, was man im
/// Alltag braucht.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("Allgemein", systemImage: "gearshape") }
            RecordingSettings().tabItem { Label("Aufnahme", systemImage: "record.circle") }
            DictationSettings().tabItem { Label("Diktat", systemImage: "mic") }
            CalendarSettings().tabItem { Label("Kalender", systemImage: "calendar") }
            VoicesView().tabItem { Label("Stimmen", systemImage: "person.wave.2") }
        }
        .frame(width: 640, height: 480)
    }
}

struct GeneralSettings: View {
    @EnvironmentObject var updates: UpdateCheck
    @State private var copied = false
    @State private var login = SMAppService.mainApp.status

    var body: some View {
        Form {
            Section {
                LabeledContent("Version", value: UpdateCheck.current)
                LabeledContent("Ordner", value: "~/" + watchDir.lastPathComponent)
                // Ohne laufende App benennt niemand fertige Aufnahmen sprechend und es gibt keine Call-Erkennung (2026-10-24).
                Toggle("Bei Anmeldung starten", isOn: Binding(get: { login == .enabled || login == .requiresApproval }, set: { on in
                    do { try on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister() } catch { appLog("Anmeldeobjekt: \(error)") }
                    login = SMAppService.mainApp.status
                }))
                if login == .requiresApproval {
                    HStack {
                        Text("macOS muss das Anmeldeobjekt noch erlauben.").foregroundStyle(.orange)
                        Button("Anmeldeobjekte öffnen …") { SMAppService.openSystemSettingsLoginItems() }
                    }
                    .font(.caption)
                }
            }
            Section {
                Toggle("Einmal täglich nach neuen Versionen suchen", isOn: Binding(get: { updates.enabled == true }, set: { updates.set($0) }))
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        if let v = updates.available {
                            Text("Version \(v) verfügbar").foregroundStyle(.tint)
                            Button(copied ? "Kopiert ✓" : "Update-Befehl kopieren") { UpdateCheck.copyCommand(); copied = true }
                        } else if let e = updates.lastError {
                            Text("Prüfung fehlgeschlagen: \(e)").foregroundStyle(.orange)
                        } else if let t = updates.lastChecked, updates.enabled == true {
                            Text("Aktuell – zuletzt geprüft \(t.formatted(date: .abbreviated, time: .shortened))").foregroundStyle(.secondary)
                        }
                        Spacer()
                        if updates.checking { ProgressView().controlSize(.small) }
                        Button("Jetzt prüfen") { Task { await updates.check() } }.disabled(updates.enabled != true || updates.checking)
                    }
                    if updates.available != nil {   // in derselben Zeile wie der Knopf – eine Trennlinie wirkte wie ein anderes Thema
                        Text("Update-Befehl im Terminal einfügen (⌘V) und Return drücken. Aufnahmen, Stimmen und Einstellungen bleiben erhalten.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Updates")
            } footer: {
                Text("""
                    Fragt nur die aktuelle Versionsnummer bei transcriber.teconomix.net ab – nichts über dich oder deine \
                    Aufnahmen. Aktualisiert wird mit dem Installationsbefehl; der Knopf kopiert ihn.
                    """)
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct RecordingSettings: View {
    @AppStorage("systemAudio") private var systemAudio = true
    @AppStorage("voiceProcessing") private var voiceProcessing = true
    @AppStorage("autoTranscribe") private var autoTranscribe = true
    @AppStorage("audioRetention") private var audioRetention = false
    @AppStorage("autoTitle") private var autoTitle = true
    @AppStorage("callDetect") private var callDetect = true
    @AppStorage("language") private var language = "de"
    @AppStorage("languages") private var languages = Core.defaultLanguages
    @State private var filter = ""
    @State private var textFormat = Core.textFormat

    var body: some View {
        Form {
            Section("Ton") {
                Toggle("Systemton mitschneiden (Videokonferenz als eigene Spur)", isOn: $systemAudio)
                    .help("Der Ton der anderen im Call. Im Raum-Meeting bleibt die Spur leer und schadet nicht.")
                Toggle("Sprachverarbeitung fürs Mikrofon (Pegel, Rausch- und Echounterdrückung)", isOn: $voiceProcessing)
                    .help("Apple Voice Processing. Aus = Rohsignal.")
            }
            Section("Nach der Aufnahme") {
                Toggle("Transkribieren", isOn: $autoTranscribe)
                Toggle("Sprechend benennen (Kalendertitel, sonst Apple-KI)", isOn: $autoTitle).disabled(!autoTranscribe)
                    .help("„Aufnahme 2026-10-10 14-03“ → „2026-10-10 14-03 Thema“; Transkript und Stimmdatenbank werden mitgezogen.")
                Picker("Transkript speichern als", selection: $textFormat) {
                    Text("Text (.txt)").tag("txt")
                    Text("Markdown (.md)").tag("md")
                }
                .onChange(of: textFormat) { _, new in Core.textFormat = new }
                Toggle("Aufnahmen nach 30 Tagen löschen (Transkripte bleiben)", isOn: $audioRetention)
                    .help("Nur fertig transkribierte Aufnahmen im Aufnahmeordner. Das Audio kommt in den Papierkorb; Transkript, Stimmen und Namen bleiben.")
                .help("Text öffnet auf jedem Mac in TextEdit. Markdown (Überschrift, Sprecher-Tabelle, fette Namen) eignet sich für Obsidian & Co. Gilt für neue Transkripte; vorhandene behalten ihr Format.")
            }
            Section("Videokonferenzen") {
                Toggle("Calls erkennen und Aufnahme anbieten", isOn: $callDetect)
                    .help("Nutzt Teams, Zoom, ein Browser … das Mikrofon, fragt eine Mitteilung „Aufnehmen?“. So gestartete Aufnahmen enden mit dem Call.")
            }
            Section {
                TextField("Suchen", text: $filter)
                ForEach(Core.allLanguages.filter { filter.isEmpty || $0.1.localizedCaseInsensitiveContains(filter) }, id: \.0) { code, name in
                    Toggle(name, isOn: binding(code))
                }
            } header: {
                // Erklärung im Kopf statt als Fußzeile: unter ~100 Sprachen sah sie niemand.
                VStack(alignment: .leading, spacing: 4) {
                    Text("Sprachen zur Auswahl")
                    Text("""
                        Diese Sprachen stehen im Fenster zur Auswahl (Aufnahmen, Dateien, Diktat). Whisper erkennt rund 100 Sprachen; \
                        am besten Englisch, Deutsch, Spanisch, Französisch und andere weit verbreitete, seltene deutlich schwächer.
                        """)
                        .font(.caption).fontWeight(.regular).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func binding(_ code: String) -> Binding<Bool> {
        Binding(get: { languages.split(separator: ",").contains { $0 == code } }, set: { on in
            var set = languages.split(separator: ",").map(String.init).filter { $0 != code }
            if on { set.append(code) }
            guard !set.isEmpty else { return }          // mindestens eine Sprache bleibt
            languages = set.joined(separator: ",")
            if !set.contains(language) { language = Core.languages(languages).first?.0 ?? set[0] }
        })
    }
}

struct DictationSettings: View {
    @EnvironmentObject var dictation: Dictation
    @AppStorage("dictation") private var dictationOn = false
    @AppStorage("dictationKey") private var dictationKey = "rcmd"
    @AppStorage("dictationCleanKey") private var dictationCleanKey = "ropt"
    @AppStorage("dictationScreenContext") private var screenContext = true
    @AppStorage("dictationVP") private var dictationVP = false
    @AppStorage("dictationIndicator") private var indicator = true
    @AppStorage("dictationSound") private var sound = true

    var body: some View {
        Form {
            Section {
                Toggle("Diktat: Taste halten, sprechen, loslassen → Text an der Schreibmarke",
                       isOn: Binding(get: { dictationOn }, set: { dictation.setEnabled($0) }))
                if dictationOn && !dictation.trusted {
                    HStack {
                        Text("Freigabe „Bedienungshilfen“ fehlt").foregroundStyle(.orange)
                        Spacer()
                        Button("Einstellungen öffnen") { Dictation.openAccessibilitySettings() }
                    }
                }
            }
            Section("Tasten") {
                Picker("Wörtlich", selection: $dictationKey) {
                    ForEach(Dictation.keys, id: \.id) { Text($0.label).tag($0.id) }
                }
                Picker("Mit KI aufräumen", selection: $dictationCleanKey) {
                    Text("aus").tag("off")
                    ForEach(Dictation.keys.filter { $0.id != dictationKey }, id: \.id) { Text($0.label).tag($0.id) }
                }
                .help("Füllwörter, Satzzeichen, Dateinamen per Apple-Modell (lokal). Bei starker Abweichung wird der Rohtext eingefügt.")
                if dictationCleanKey != "off", let why = DictationCleanup.unavailableReason {
                    Text(why).foregroundStyle(.orange)
                }
                Toggle("Text des aktiven Fensters als Kontext (Namen, Dateinamen)", isOn: $screenContext)
                    .disabled(dictationCleanKey == "off")
                    .help("Beim KI-Aufräumen wird der Text des vordersten Fensters lokal erkannt und nur dem Apple-Modell gegeben. Nichts wird gespeichert.")
            }
            Section("Rückmeldung") {
                Toggle("Ton, sobald das Mikrofon aufnimmt", isOn: $sound)
                Toggle("Symbol an der Schreibmarke", isOn: $indicator)
                Toggle("Sprachverarbeitung (startet ~1 s langsamer)", isOn: $dictationVP)
                    .onChange(of: dictationVP) { _, _ in dictation.settingsChanged() }
            }
        }
        .formStyle(.grouped)
    }
}

struct CalendarSettings: View {
    @AppStorage("useCalendar") private var useCalendar = true
    @State private var access = EKEventStore.authorizationStatus(for: .event) == .fullAccess
    @State private var excluded = CalendarContext.excluded
    @State private var groups: [(String, [EKCalendar])] = []

    var body: some View {
        Form {
            Section {
                Toggle("Termin zur Aufnahme nutzen (Titel, Teilnehmer)", isOn: $useCalendar)
                    .help("Läuft beim Start ein Termin, werden Titel und Teilnehmer neben der Aufnahme gespeichert: Dateiname, Vorschläge beim Benennen, Sprecherzahl.")
                if !access {
                    HStack {
                        Text("Kein Kalenderzugriff").foregroundStyle(.orange)
                        Spacer()
                        Button("Zugriff erlauben") { Task { access = await CalendarContext.access(); reload() } }
                    }
                }
            } footer: {
                Text("""
                    Termine, bei denen du Teilnehmer oder Organisator bist, haben Vorrang vor Terminen aus geteilten Kalendern. \
                    In der Kalender-App ausgeblendete Kalender sieht Transcriber trotzdem – hier abwählen.
                    """)
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(groups, id: \.0) { account, cals in
                Section(account) {
                    ForEach(cals, id: \.calendarIdentifier) { c in
                        Toggle(isOn: binding(c.calendarIdentifier)) {
                            HStack(spacing: 6) {
                                Circle().fill(Color(cgColor: c.cgColor)).frame(width: 9, height: 9)
                                Text(c.title)
                                if !c.allowsContentModifications { Text("nur lesen").font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                    }
                }
            }
            .disabled(!useCalendar)
        }
        .formStyle(.grouped)
        .onAppear(perform: reload)
    }

    private func reload() {
        guard access else { groups = []; return }
        var by: [String: [EKCalendar]] = [:]
        for c in CalendarContext.calendars() { by[c.source.title, default: []].append(c) }
        groups = by.keys.sorted().map { ($0, by[$0]!) }
    }

    private func binding(_ id: String) -> Binding<Bool> {
        Binding(get: { !excluded.contains(id) }, set: { on in
            if on { excluded.remove(id) } else { excluded.insert(id) }
            CalendarContext.excluded = excluded
        })
    }
}
