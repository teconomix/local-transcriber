import EventKit
import ServiceManagement
import SwiftUI

/// Einstellungen (eigenes Fenster, Navigation links): Allgemein · Aufnahme · Diktat · Kalender · Glossar · KI · Stimmen. Das Panel enthält nur, was man im
/// Alltag braucht.
struct SettingsView: View {
    @AppStorage("settingsTab") private var tab = "allgemein"   // „ki“: vom Eintrag aus direkt dorthin
    /// Navigation links wie in den macOS-Systemeinstellungen: Mit „KI“ passten sieben Reiter nicht mehr in die Leiste –
    /// macOS 26 versteckte sie hinter einem »-Menü (Björn, 2026-10-24).
    static let pages: [(id: String, title: LocalizedStringKey, icon: String)] = [
        ("allgemein", "Allgemein", "gearshape"), ("aufnahme", "Aufnahme", "record.circle"), ("diktat", "Diktat", "mic"),
        ("kalender", "Kalender", "calendar"), ("glossar", "Glossar", "character.book.closed"), ("ki", "KI", "sparkles"),
        ("stimmen", "Stimmen", "person.wave.2"),
    ]

    var body: some View {
        NavigationSplitView {
            List(Self.pages, id: \.id, selection: Binding(get: { tab }, set: { if let v = $0 { tab = v } })) { p in
                Label(p.title, systemImage: p.icon).tag(p.id)
            }
            .navigationSplitViewColumnWidth(170)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            Group {
                switch tab {
                case "aufnahme": RecordingSettings()
                case "diktat": DictationSettings()
                case "kalender": CalendarSettings()
                case "glossar": GlossarySettings()
                case "ki": AISettings()
                case "stimmen": VoicesView()
                default: GeneralSettings()
                }
            }
            .navigationTitle(Self.pages.first { $0.id == tab }?.title ?? "Einstellungen")
        }
        .frame(width: 800, height: 520)
    }
}

struct GeneralSettings: View {
    @EnvironmentObject var updates: UpdateCheck
    @State private var copied = false
    @State private var login = SMAppService.mainApp.status
    @AppStorage("panelDays") private var panelDays = 7
    @AppStorage("panelSort") private var panelSort = LibraryModel.Sort.activity.rawValue

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
                VStack(alignment: .leading, spacing: 4) {
                    Picker("Liste im Panel", selection: $panelDays) {
                        Text("Letzten Tag").tag(1); Text("Letzte 3 Tage").tag(3); Text("Letzte 7 Tage").tag(7)
                        Text("Letzte 30 Tage").tag(30); Text("Alle").tag(0)
                    }
                    Picker("Sortierung im Panel", selection: $panelSort) {
                        Text("Zuletzt bearbeitet").tag(LibraryModel.Sort.activity.rawValue)
                        Text("Aufnahmedatum").tag(LibraryModel.Sort.recorded.rawValue)
                        Text("Titel").tag(LibraryModel.Sort.title.rawValue)
                        Text("Länge").tag(LibraryModel.Sort.length.rawValue)
                    }
                    Text("Nur für die Liste im Panel: Einträge, die in diesem Zeitraum zuletzt bearbeitet wurden (transkribiert, benannt, zusammengefasst, umbenannt). Neu geordnet wird beim Öffnen des Panels. Alles zeigt das Fenster „Alle Transkriptionen“.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
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
    @AppStorage("nameDateFormat") private var nameFormat = RecordingName.standard
    @State private var customFormat = false             // „Eigenes Format“ gewählt, auch solange das Feld noch leer ist
    @AppStorage("callDetect") private var callDetect = true
    @AppStorage("icloudInbox") private var icloudInbox = false
    @AppStorage("airdropInbox") private var airdropInbox = false
    @AppStorage("language") private var language = "de"
    @AppStorage("languages") private var languages = Core.defaultLanguages
    @State private var filter = ""
    @State private var textFormat = Core.textFormat
    @EnvironmentObject var dictation: Dictation
    @State private var asrModel = ""                       // leer, bis der Kern geantwortet hat
    @State private var asrCurrent = ""             // was der Kern eingestellt hat (loadModels)
    @State private var asrInstalled: Set<String> = []
    @State private var asrBusy: String?                    // Hinweis während Laden/Löschen
    @State private var asrError: String?
    @State private var asrRemove: String?
    static let asrLabels: [(id: String, label: LocalizedStringKey)] = [
        ("turbo-8bit", "Whisper turbo, 8 Bit (0,9 GB)"), ("turbo", "Whisper turbo, 16 Bit (1,6 GB)")]

    var body: some View {
        Form {
            Section("Ton") {
                Toggle("Systemton mitschneiden (Videokonferenz als eigene Spur)", isOn: $systemAudio)
                    .help("Der Ton der anderen im Call. Im Raum-Meeting bleibt die Spur leer und schadet nicht.")
                Toggle("Sprachverarbeitung fürs Mikrofon (Pegel, Rausch- und Echounterdrückung)", isOn: $voiceProcessing)
                    .help("Apple Voice Processing. Aus = Rohsignal.")
            }
            Section("Spracherkennung") {
                Picker("Modell", selection: $asrModel) {
                    if asrModel.isEmpty { Text(verbatim: "…").tag("") }
                    ForEach(Self.asrLabels, id: \.id) { Text($0.label).tag($0.id) }
                }
                .disabled(asrBusy != nil || asrModel.isEmpty)
                .onChange(of: asrModel) { old, new in
                    // new == asrCurrent: loadModels hat zurückgestellt (Wechsel gescheitert) – kein zweiter Wechsel
                    guard !old.isEmpty, !new.isEmpty, new != old, new != asrCurrent, asrBusy == nil else { return }
                    Task { await switchModel(to: new, from: old) }
                }
                Text("8 Bit erkennt gemessen gleich genau, braucht aber halb so viel Platz und rund 0,8 GB weniger Arbeitsspeicher. Ein noch nicht geladenes Modell wird beim Wechsel einmal aus dem Internet geladen; es gilt ab dem nächsten Auftrag.")
                    .font(.caption).foregroundStyle(.secondary)
                if let asrBusy {
                    HStack(spacing: 6) { ProgressView().controlSize(.small); Text(asrBusy) }
                }
                ForEach(Self.asrLabels.filter { $0.id != asrModel && asrInstalled.contains($0.id) }, id: \.id) { m in
                    HStack {
                        Text("\(Text(m.label)) liegt noch auf diesem Mac, wird aber nicht genutzt.").font(.caption)
                        Spacer()
                        Button("Löschen …") { asrRemove = m.id }.disabled(asrBusy != nil)
                    }
                }
                if let asrError { Text(asrError).font(.caption).foregroundStyle(.red) }
            }
            .task { await loadModels() }
            .confirmationDialog("Nicht genutztes Modell löschen?", isPresented: Binding(get: { asrRemove != nil }, set: { if !$0 { asrRemove = nil } })) {
                Button("Löschen", role: .destructive) { if let m = asrRemove { Task { await removeModel(m) } } }
            } message: {
                Text("Es lässt sich jederzeit wieder laden, indem du es hier auswählst. Andere Programme, die dasselbe Modell aus dem Hugging-Face-Zwischenspeicher nutzen, müssten es dann neu laden.")
            }
            Section("Nach der Aufnahme") {
                Toggle("Transkribieren", isOn: $autoTranscribe)
                Toggle("Sprechend benennen (Kalendertitel, sonst Apple-KI)", isOn: $autoTitle).disabled(!autoTranscribe)
                    .help("„Aufnahme 2026-10-10 14-03“ → „2026-10-10 14-03 Thema“; Transkript und Stimmdatenbank werden mitgezogen.")
                Picker("Datum im Dateinamen", selection: Binding(
                    get: { customFormat || !RecordingName.presets.contains(nameFormat) ? "custom" : nameFormat },
                    set: { v in customFormat = v == "custom"; if v != "custom" { nameFormat = v } })) {
                    ForEach(RecordingName.presets, id: \.self) { f in Text(verbatim: RecordingName.stamp(Date(), format: f)).tag(f) }
                    Text("Eigenes Format …").tag("custom")
                }
                if customFormat || !RecordingName.presets.contains(nameFormat) {
                    TextField("Format", text: $nameFormat, prompt: Text(verbatim: "yyMMdd HHmm"))
                    Text("yyyy oder yy = Jahr, MM = Monat, dd = Tag, HH = Stunde, mm = Minute; dazwischen Leerzeichen, - _ oder Punkt.")
                        .font(.caption).foregroundStyle(.secondary)
                    if RecordingName.valid(nameFormat) == nil {
                        Text("Ungültig – es gilt der Standard.").font(.caption).foregroundStyle(.orange)
                    }
                }
                Text(verbatim: "\(RecordingName.defaultName(Date())) → \(RecordingName.stamp(Date())) \(String(localized: "Thema"))")
                    .font(.caption).foregroundStyle(.secondary)
                    .help("Gilt für neue Aufnahmen aus der App, per AirDrop und vom iPhone-Kurzbefehl; vorhandene Dateien behalten ihren Namen.")
                Picker("Transkript speichern als", selection: $textFormat) {
                    Text("Text (.txt)").tag("txt")
                    Text("Markdown (.md)").tag("md")
                }
                .onChange(of: textFormat) { _, new in Core.textFormat = new }
                .help("Text öffnet auf jedem Mac in TextEdit. Markdown (Überschrift, Sprecher-Tabelle, fette Namen) eignet sich für Obsidian & Co. Gilt für neue Transkripte; vorhandene behalten ihr Format.")
                Toggle(isOn: $audioRetention) {
                    Text("Audio nach 30 Tagen löschen (Transkripte bleiben)")
                    Text("Alle fertig transkribierten Audio- und Videodateien in ~/Transcriber samt Unterordnern, 30 Tage nach dem Transkript. Sie kommen in den Papierkorb; Transkript, Zusammenfassung und Stimmen bleiben.")
                }
            }
            Section("iPhone") {
                Toggle("Aufnahmen vom iPhone aus iCloud Drive holen", isOn: $icloudInbox).disabled(!ICloudInbox.available)
                    .help("Ordner „iCloud Drive › Transcriber“ und „iCloud Drive › Kurzbefehle › Transcriber“: Was dort ankommt, verschiebt die App nach ~/Transcriber/iPhone und transkribiert es. In iCloud bleibt nichts zurück.")
                if !ICloudInbox.available {
                    Text("iCloud Drive ist auf diesem Mac nicht eingeschaltet.").font(.caption).foregroundStyle(.secondary)
                } else if icloudInbox {
                    Text("Die Aufnahme liegt kurz in iCloud, bis dieser Mac sie abholt. Für vertrauliche Gespräche „Erweiterten Datenschutz“ für iCloud einschalten oder AirDrop nehmen.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Ordner im Finder zeigen") {
                        try? FileManager.default.createDirectory(at: ICloudInbox.inbox, withIntermediateDirectories: true)
                        NSWorkspace.shared.activateFileViewerSelecting([ICloudInbox.inbox])
                    }
                    HStack(alignment: .top, spacing: 14) {
                        if let qr = ICloudInbox.qrCode(ICloudInbox.shortcutWebURL) {
                            Image(nsImage: qr).interpolation(.none)
                                .padding(6).background(.white, in: RoundedRectangle(cornerRadius: 6))
                                .help(ICloudInbox.shortcutWebURL.absoluteString)
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Kurzbefehl „\(ICloudInbox.shortcutName)“ aufs iPhone").bold()
                            Text("Mit der Kamera des iPhones scannen oder per AirDrop schicken, dann „Kurzbefehl hinzufügen“. Danach eine Aufnahme z. B. in Sprachmemos teilen › „\(ICloudInbox.shortcutName)“ – den Rest erledigt dieser Mac.")
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            Button("Per AirDrop senden …") { ICloudInbox.sendShortcutViaAirDrop() }
                                .disabled(ICloudInbox.shortcutFile == nil)
                        }
                    }
                }
                Toggle("Per AirDrop empfangene Aufnahmen übernehmen", isOn: $airdropInbox)
                    .onChange(of: airdropInbox) { _, on in AirDropInbox.setEnabled(on) }
                Text("Ohne Cloud: am iPhone Teilen › AirDrop › dieser Mac. Transcriber schaut dafür im Download-Ordner nur nach Audiodateien, die per AirDrop ankommen, und verschiebt sie nach ~/Transcriber/iPhone. Andere Dateien bleiben unberührt. macOS fragt beim Einschalten einmal nach dem Zugriff auf „Downloads“.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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

    private func loadModels() async {
        guard let m = await Core.asrModels() else { asrError = String(localized: "Modell-Stand nicht lesbar (Protokoll: app.log)"); return }
        asrInstalled = m.installed
        asrCurrent = m.current
        asrModel = m.current
    }

    private func switchModel(to new: String, from old: String) async {
        asrError = nil
        asrBusy = asrInstalled.contains(new) ? String(localized: "Modell wird eingestellt …") : String(localized: "Modell wird geladen …")
        let (ok, out) = await Core.run(["model", new, "--download"])
        asrBusy = nil
        if ok {
            dictation.modelChanged()                  // Diktat-Dienst hält das alte Modell geladen
        } else {
            appLog("Modellwechsel \(new) fehlgeschlagen: \(out)")
            asrError = out.split(separator: "\n").last.map(String.init) ?? out
        }
        await loadModels()                            // zeigt, was wirklich eingestellt ist (bei Fehler: das alte)
    }

    private func removeModel(_ m: String) async {
        asrError = nil; asrBusy = String(localized: "Modell wird gelöscht …")
        let (ok, out) = await Core.run(["model", "--remove", m])
        asrBusy = nil
        if !ok {
            appLog("Modell \(m) nicht gelöscht: \(out)")
            asrError = out.split(separator: "\n").last.map(String.init) ?? out
        }
        await loadModels()
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
            } footer: {
                // Gemessen 2026-10-24: Diktat-Dienst 2,6 GB (2,5 GB GPU), nach dem Ausschalten 2,4 GB frei.
                Text("Bei eingeschaltetem Diktat können bis zu 2,5 GB Arbeitsspeicher belegt sein – damit der Text sofort da ist.")
                    .font(.caption).foregroundStyle(.secondary)
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

/// Glossar (vocab.txt, Format siehe transcriber/glossary.py): Begriff = Schreibweisen, die nach der Erkennung ersetzt
/// werden. Dieselbe Datei wie `transcriber vocab` – Kommentarzeilen am Anfang bleiben, Kommentare hinter Einträgen nicht.
struct GlossarySettings: View {
    struct Entry: Identifiable, Equatable {
        let id = UUID()
        var term: String
        var variants: String
    }
    @State private var entries: [Entry] = []
    @State private var header: [String] = []
    @State private var loaded: [Entry] = []          // nur nach echter Änderung schreiben (Öffnen ändert nichts)
    @FocusState private var focused: UUID?

    private static var url: URL { Core.data.appendingPathComponent("vocab.txt") }

    // Kein Form: das gruppierte Formular richtet Textfelder rechtsbündig aus und setzt eigene Breiten – für eine
    // Tabelle zum Tippen ungeeignet. Aufbau wie dort: Kopf mit Erklärung, Kasten, Fußzeile.
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Glossar").font(.headline)
                    Text("""
                        Namen und Fachbegriffe, die die Spracherkennung falsch schreibt, werden danach ersetzt – auch in \
                        Wörtern mit Bindestrich („Kali-Strategie“ → „KI-Strategie“). Gilt für neue Transkripte und das Diktat; \
                        für vorhandene: „Neu auswerten“ › „Glossar anwenden“.
                        """)
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 10)
                VStack(alignment: .leading, spacing: 8) {
                    Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                        GridRow {
                            Text("Richtig geschrieben").font(.caption).foregroundStyle(.secondary)
                            Text("Wird erkannt als (mit Komma getrennt)").font(.caption).foregroundStyle(.secondary)
                            Color.clear.frame(width: 16, height: 1)
                        }
                        ForEach($entries) { $e in
                            GridRow {
                                TextField(text: $e.term, prompt: Text("z. B. KI")) { EmptyView() }
                                    .focused($focused, equals: e.id)
                                    .frame(width: 170)
                                TextField(text: $e.variants, prompt: Text("z. B. Kali, K.I.")) { EmptyView() }
                                Button { entries.removeAll { $0.id == e.id } } label: { Image(systemName: "minus.circle") }
                                    .buttonStyle(.borderless).help("Eintrag entfernen")
                            }
                        }
                    }
                    .textFieldStyle(.roundedBorder)
                    Button { let e = Entry(term: "", variants: ""); entries.append(e); focused = e.id } label: {
                        Label("Begriff hinzufügen", systemImage: "plus")
                    }
                    .buttonStyle(.borderless)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
                Text("Vorsicht bei echten Wörtern als Schreibweise: Sie werden überall ersetzt. Ohne Schreibweise bleibt der Begriff nur als Schreibvorgabe fürs KI-Aufräumen im Diktat.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10)
            }
            .padding(20)
        }
        .onAppear(perform: load)
        .onChange(of: entries) { _, _ in save() }
    }

    private func load() {
        let text = (try? String(contentsOf: Self.url, encoding: .utf8)) ?? ""
        var head: [String] = [], list: [Entry] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let body = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            if body.trimmingCharacters(in: .whitespaces).isEmpty {
                if list.isEmpty && line.hasPrefix("#") { head.append(line) }
                continue
            }
            let parts = body.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            list.append(Entry(term: parts[0].trimmingCharacters(in: .whitespaces),
                              variants: parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""))
        }
        header = head.isEmpty ? ["# Glossar für transcriber – Format: Begriff = Schreibweise1, Schreibweise2 (werden nach der Erkennung ersetzt)"] : head
        entries = list; loaded = list
    }

    private func save() {
        guard entries != loaded else { return }
        // Halbe Eingaben (leerer Begriff) nicht schreiben, aber in der Liste lassen; „#“ und „=“ würden das Format brechen.
        let clean = { (s: String) in s.replacingOccurrences(of: "#", with: "").trimmingCharacters(in: .whitespaces) }
        let lines = entries.compactMap { e -> String? in
            let t = clean(e.term).replacingOccurrences(of: "=", with: "")
            guard !t.isEmpty else { return nil }
            let v = clean(e.variants).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return v.isEmpty ? t : t + " = " + v.joined(separator: ", ")
        }
        do {
            try FileManager.default.createDirectory(at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try (header + lines).joined(separator: "\n").appending("\n").write(to: Self.url, atomically: true, encoding: .utf8)
        } catch { appLog("Glossar speichern: \(error)") }
    }
}
