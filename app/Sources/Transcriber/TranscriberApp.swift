import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

@main
struct TranscriberApp: App {
    @StateObject private var recorder = Recorder()
    @StateObject private var jobs = JobManager()
    @StateObject private var dictation = Dictation()
    @StateObject private var calls = CallDetector()
    private let uiTest = CommandLine.arguments.contains("--ui-test")

    init() {
        if CommandLine.arguments.contains("--vp-test") { VPTest.run(); exit(0) }
        if CommandLine.arguments.contains("--latency-test") { VPTest.latency(); exit(0) }
        if CommandLine.arguments.contains("--tap-test") { VPTest.tap(); exit(0) }
        if CommandLine.arguments.contains("--calendar-test") { Task { await VPTest.calendar(); exit(0) } }
        if CommandLine.arguments.contains("--cleanup-test") { Task { await VPTest.cleanup(); exit(0) } }
        if let i = CommandLine.arguments.firstIndex(of: "--title-test") {
            let files = CommandLine.arguments[(i + 1)...].map { URL(fileURLWithPath: $0) }
            Task { await VPTest.titles(files); exit(0) }
        }
    }

    var body: some Scene {
        MenuBarExtra {
            PanelView().environmentObject(recorder).environmentObject(jobs).environmentObject(dictation).environmentObject(calls)
        } label: {
            MenuLabel().environmentObject(recorder).environmentObject(jobs).environmentObject(dictation)
                .onAppear {
                    let r = recorder, j = jobs
                    dictation.micBusy = { r.isRecording }
                    calls.isRecording = { r.isRecording }
                    calls.startRecording = { Task { try? await Control.start(r) } }
                    calls.stopRecording = { Task { await Control.stop(r, j) } }
                }
        }
        .menuBarExtraStyle(.window)
        .onChange(of: uiTest, initial: true) { _, on in
            guard on else { return }
            Task { await VPTest.ui(recorder: recorder, jobs: jobs, dictation: dictation, calls: calls); exit(0) }
        }

        Window("Stimmen", id: "voices") { VoicesView() }
        Window("Einstellungen", id: "settings") {
            SettingsView().environmentObject(dictation).environmentObject(calls)
        }
        .windowResizability(.contentSize)
    }
}

let watchDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Transkription")

/// Aufnahme starten/stoppen mit den Einstellungen aus dem Panel – vom Knopf und von der Call-Erkennung genutzt.
@MainActor
enum Control {
    /// Termin der laufenden Aufnahme (beim Start ermittelt, beim Stopp neben die Datei gelegt).
    private static var event: [String: Any]?

    static func start(_ recorder: Recorder) async throws {
        event = nil
        if CalendarContext.enabled {
            Task {
                guard await CalendarContext.access(), let e = CalendarContext.current() else { return }
                event = CalendarContext.info(e)
                appLog("Termin zur Aufnahme: \(e.title ?? "?") (\(e.attendees?.count ?? 0) Teilnehmer)")
            }
        }
        let d = UserDefaults.standard
        let mic = d.string(forKey: "micID") ?? ""
        recorder.warning = nil
        try await recorder.start(deviceID: mic.isEmpty ? nil : mic, systemAudio: d.object(forKey: "systemAudio") as? Bool ?? true,
                                 voiceProcessing: d.object(forKey: "voiceProcessing") as? Bool ?? true,
                                 folder: watchDir.appendingPathComponent("Aufnahmen"))
    }

    static func stop(_ recorder: Recorder, _ jobs: JobManager) async {
        let d = UserDefaults.standard
        let url = await recorder.stop()
        if let url, let e = event { CalendarContext.write(e, next: url) }
        event = nil
        if let url, d.object(forKey: "autoTranscribe") as? Bool ?? true {
            jobs.add(url, language: d.string(forKey: "language") ?? "de")
        }
    }
}

/// Menüleiste: Aufnahme (rot + Zeit) hat Vorrang, dann Diktat, sonst Fortschritt laufender Transkriptionen in Prozent.
struct MenuLabel: View {
    @EnvironmentObject var recorder: Recorder
    @EnvironmentObject var jobs: JobManager
    @EnvironmentObject var dictation: Dictation
    var body: some View {
        if (dictation.state == .recording || dictation.state == .starting) && !recorder.isRecording {
            Image(systemName: "mic.fill")
        } else if dictation.state == .transcribing && !recorder.isRecording {
            Image(systemName: "text.bubble")
        } else if recorder.isRecording {
            HStack(spacing: 3) {
                Image(systemName: "record.circle.fill")
                Text(String(format: "%d:%02d", Int(recorder.elapsed) / 60, Int(recorder.elapsed) % 60)).monospacedDigit()
            }
        } else if let p = jobs.overallProgress {
            HStack(spacing: 3) {
                Image(systemName: "waveform.badge.ellipsis")
                Text("\(Int(p * 100)) %").monospacedDigit()
            }
        } else {
            Image(systemName: "waveform")
        }
    }
}

struct PanelView: View {
    @EnvironmentObject var recorder: Recorder
    @EnvironmentObject var jobs: JobManager
    @EnvironmentObject var dictation: Dictation
    @EnvironmentObject var calls: CallDetector
    @AppStorage("dictation") private var dictationOn = false
    @AppStorage("dictationKey") private var dictationKey = "rcmd"
    @AppStorage("dictationCleanKey") private var dictationCleanKey = "ropt"
    @AppStorage("micID") private var micID = ""
    @AppStorage("language") private var language = "de"
    @AppStorage("languages") private var languages = Core.defaultLanguages
    @State private var mics: [AVCaptureDevice] = Recorder.microphones()
    @State private var error: String?
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "waveform").foregroundStyle(.tint)
                Text("Transcriber").font(.headline)
                Spacer()
                Text(status).font(.caption).foregroundStyle(recorder.isRecording ? .red : .secondary).monospacedDigit()
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                        GridRow {
                            Button { toggleRecording() } label: {
                                Label(recorder.isRecording ? "Aufnahme beenden" : "Aufnahme starten",
                                      systemImage: recorder.isRecording ? "stop.circle.fill" : "record.circle")
                                    .frame(maxWidth: .infinity)
                            }
                            .keyboardShortcut(.defaultAction)
                            .tint(recorder.isRecording ? .red : .accentColor)
                            FillMenu(selection: $micID,
                                     options: [("", "Systemstandard")] + mics.map { ($0.uniqueID, $0.localizedName) })
                            .frame(width: 170)
                            .disabled(recorder.isRecording)
                            .onAppear { mics = Recorder.microphones() }
                            .help("Mikrofon")
                        }
                        GridRow {
                            Button { pickFiles() } label: {
                                Label("Datei transkribieren …", systemImage: "doc.badge.plus").frame(maxWidth: .infinity)
                            }
                            FillMenu(selection: $language, options: Core.languages(languages))
                                .frame(width: 170).help("Sprache für Aufnahmen, Dateien und Diktat")
                        }
                    }
                    .controlSize(.large)
                    if recorder.isRecording {
                        HStack(spacing: 8) {
                            Image(systemName: "record.circle.fill").foregroundStyle(.red)
                            Text(timeString(recorder.elapsed)).monospacedDigit()
                            ProgressView(value: Double(recorder.level)).tint(.red)
                        }
                        .font(.callout)
                    }
                    if let c = calls.current {
                        Label("Call in \(c) erkannt", systemImage: "phone.fill").font(.caption).foregroundStyle(.secondary)
                    }
                    if let w = recorder.warning { Text(w).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
                    Divider()
                    dictationLine
                }
                .padding(6)
            }

            if !jobs.jobs.isEmpty {
                HStack {
                    Text("Transkriptionen").font(.subheadline.weight(.semibold))
                    Spacer()
                    if jobs.jobs.contains(where: { $0.state != .running }) {
                        Button("Erledigte ausblenden") { jobs.clearFinished() }.controlSize(.small).buttonStyle(.link)
                    }
                }
                // Keine ScrollView: im selbst bemessenden Menüleistenfenster schrumpft sie auf Höhe 0.
                VStack(alignment: .leading, spacing: 10) { ForEach(jobs.jobs.prefix(5)) { JobRow(job: $0) } }
            }
            if let e = error ?? jobs.launchError { Text(e).font(.caption).foregroundStyle(.red) }

            Divider()
            HStack {
                Button("Ordner öffnen") { NSWorkspace.shared.open(watchDir) }
                Button("Stimmen …") { openWindow(id: "voices"); NSApp.activate(ignoringOtherApps: true) }
                Button("Einstellungen …") { openWindow(id: "settings"); NSApp.activate(ignoringOtherApps: true) }
                    .keyboardShortcut(",")
                Spacer()
                Button("Beenden") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 440)
    }

    private var status: String {
        if recorder.isRecording { return "Aufnahme " + timeString(recorder.elapsed) }
        if let p = jobs.overallProgress { return "Transkribiere \(Int(p * 100)) %" }
        return "Bereit"
    }

    /// Diktat im Panel nur als Hinweiszeile: welche Tasten, und rot/orange, wenn etwas fehlt.
    @ViewBuilder private var dictationLine: some View {
        let label = { (id: String) in Dictation.keys.first { $0.id == id }?.label ?? id }
        HStack(spacing: 6) {
            Image(systemName: "mic").foregroundStyle(.secondary)
            if !dictationOn {
                Text("Diktat aus").foregroundStyle(.secondary)
            } else if !dictation.trusted {
                Text("Diktat: Freigabe „Bedienungshilfen“ fehlt").foregroundStyle(.orange)
                Button("Öffnen") { Dictation.openAccessibilitySettings() }.controlSize(.small)
            } else if let e = dictation.lastError {
                Text("Diktat: \(e)").foregroundStyle(.red).lineLimit(2).textSelection(.enabled)
            } else {
                Text("Diktat: \(label(dictationKey))" + (dictationCleanKey == "off" ? "" : " · mit KI: \(label(dictationCleanKey))"))
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
    }

    private func toggleRecording() {
        error = nil
        Task {
            if recorder.isRecording {
                await Control.stop(recorder, jobs)
            } else {
                do { try await Control.start(recorder) } catch { self.error = error.localizedDescription }
            }
        }
    }

    private func pickFiles() {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
        p.allowedContentTypes = [.audio, .movie, .mpeg4Audio, .mpeg4Movie]
        NSApp.activate(ignoringOtherApps: true)
        if p.runModal() == .OK { for u in p.urls { jobs.add(u, language: language) } }
    }

    private func timeString(_ t: TimeInterval) -> String {
        String(format: "%d:%02d:%02d", Int(t) / 3600, Int(t) / 60 % 60, Int(t) % 60)
    }
}

/// Auswahlknopf, der die vorgegebene Breite ausfüllt und beim Klick ein natives Menü öffnet. Picker und Menu behalten
/// auf macOS ihre natürliche Breite (bzw. bauen ihre Beschriftung selbst) – so standen „Systemstandard“ und „Deutsch“
/// im Panel nicht bündig.
struct FillMenu: View {
    @Binding var selection: String
    let options: [(String, String)]

    var body: some View {
        Button(action: show) {
            HStack {
                Text(options.first { $0.0 == selection }?.1 ?? options.first?.1 ?? "").lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func show() {
        let menu = NSMenu()
        for (id, title) in options {
            let item = ClosureMenuItem(title: title) { selection = id }
            item.state = id == selection ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: menu.items.first { $0.state == .on }, at: NSEvent.mouseLocation, in: nil)
    }
}

final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void
    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError("nicht benutzt") }
    @objc private func fire() { handler() }
}

/// Einfaches Fließlayout: Elemente nebeneinander, Umbruch, wenn die Zeile voll ist (Namensvorschläge).
struct FlowRow: Layout {
    var spacing: CGFloat = 4
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, maxX: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > w { x = 0; y += row + spacing; row = 0 }
            x += s.width + spacing; row = max(row, s.height); maxX = max(maxX, x - spacing)
        }
        return CGSize(width: maxX, height: y + row)
    }
    func placeSubviews(in b: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = b.minX, y = b.minY, row: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > b.minX && x + s.width > b.maxX { x = b.minX; y += row + spacing; row = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing; row = max(row, s.height)
        }
    }
}

struct JobRow: View {
    @ObservedObject var job: Job
    @EnvironmentObject var jobs: JobManager
    @State private var names: [String: String] = [:]
    @State private var editing: Set<String> = []     // Sprecher, deren Namensfeld per ✎ geöffnet wurde
    @State private var hovered: String?

    init(job: Job, editing: Set<String> = []) {        // editing vorbelegt nur für den Foto-Test (--ui-test)
        self.job = job
        _editing = State(initialValue: editing)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(job.source.deletingPathExtension().lastPathComponent)
                        .lineLimit(1).truncationMode(.middle).font(.callout.weight(.medium))
                    if job.state == .done { fileLine }
                }
                Spacer(minLength: 4)
                if job.state != .running {
                    Button { jobs.hide(job) } label: { Image(systemName: "xmark").font(.caption.weight(.semibold)) }
                        .buttonStyle(.borderless).foregroundStyle(.secondary).help("Aus der Liste entfernen (Dateien bleiben)")
                }
            }
            switch job.state {
            case .running:
                ProgressView(value: job.progress) { Text(job.message).font(.caption) }
            case .failed, .aborted:
                Text(job.error ?? "fehlgeschlagen").font(.caption).foregroundStyle(.red).textSelection(.enabled)
            case .done:
                VStack(alignment: .leading, spacing: 2) { ForEach(job.speakers) { s in speakerRow(s) } }
                // Ab zwei offenen Zuordnungen; eine einzelne übernimmt das ✓ in ihrer Zeile.
                if job.speakers.filter({ $0.status == "sicher" || $0.status == "vermutlich" }).count >= 2 {
                    Button { Task { await jobs.confirm(job) } } label: { Label("Alle Zuordnungen übernehmen", systemImage: "checkmark.circle") }
                        .buttonStyle(.link).font(.caption)
                        .help("Alle automatischen Zuordnungen bestätigen – verbessert die Erkennung künftiger Aufnahmen")
                }
                if let e = job.error { Text(e).font(.caption).foregroundStyle(.red) }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
    }

    /// Dauer und Dateiaktionen als Text direkt unter dem Titel – erklärt sich ohne Tooltip.
    private var fileLine: some View {
        HStack(spacing: 6) {
            Text(String(format: "%d:%02d min", Int(job.duration) / 60, Int(job.duration) % 60)).foregroundStyle(.secondary)
            Text("·").foregroundStyle(.tertiary)
            Button("Öffnen") { if let m = job.mdURL { NSWorkspace.shared.open(m) } }.buttonStyle(.link)
            Text("·").foregroundStyle(.tertiary)
            Button("Im Finder") { if let m = job.mdURL ?? job.jsonURL { NSWorkspace.shared.activateFileViewerSelecting([m]) } }
                .buttonStyle(.link)
        }
        .font(.caption)
    }

    @ViewBuilder private func speakerRow(_ s: Speaker) -> some View {
        let open = editing.contains(s.letter)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(s.letter).font(.caption.monospaced()).foregroundStyle(.tertiary)
                Button { editing.formSymmetricDifference([s.letter]) } label: {
                    Text(s.display).font(.callout.weight(s.needsName ? .semibold : .regular))
                }
                .buttonStyle(.plain).help("Umbenennen")
                Text(String(format: "%.1f min", s.speechMin)).font(.caption).foregroundStyle(.secondary)
                if s.status == "vermutlich", let c = s.candidates.first, !open {
                    Button { Task { await jobs.name(job, letter: s.letter, name: c.0) } } label: {
                        Label("übernehmen", systemImage: "checkmark").font(.caption)
                    }
                    .buttonStyle(.link).help("„\(c.0)“ als richtig bestätigen")
                } else if s.status == "sicher" || s.status == "bestätigt" {
                    Text(s.status).font(.caption).foregroundStyle(.tertiary)
                }
                if !open {
                    Button { editing.insert(s.letter) } label: { Image(systemName: "pencil").font(.caption) }
                        .buttonStyle(.borderless).foregroundStyle(hovered == s.letter ? .primary : .tertiary).help("Umbenennen")
                }
                Spacer(minLength: 0)
            }
            if open { nameEditor(s) }
        }
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(hovered == s.letter || open ? 0.07 : 0)))
        .onHover { hovered = $0 ? s.letter : (hovered == s.letter ? nil : hovered) }
    }

    /// Namensfeld mit wenigen, passenden Vorschlägen. Feld leer: Teilnehmer dieses Termins + die zwei ähnlichsten
    /// Stimmen. Beim Tippen: alle passenden Namen. Kalender-Teilnehmer, die zu einer bekannten Stimme passen („Kim“ ↔
    /// „Kim Beispiel“), erscheinen unter deren Namen. Ein Klick benennt sofort – derselbe Name landet immer bei
    /// derselben Person.
    @ViewBuilder private func nameEditor(_ s: Speaker) -> some View {
        let typed = (names[s.letter] ?? "").trimmingCharacters(in: .whitespaces)
        let opts: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        let known = jobs.knownNames
        let resolve = { (a: String) -> String in
            known.first { k in k.compare(a, options: opts) == .orderedSame
                || k.range(of: a + " ", options: opts.union(.anchored)) != nil
                || a.range(of: k + " ", options: opts.union(.anchored)) != nil } ?? a
        }
        let attendees = job.attendees.map(resolve)
        let pool: [String] = typed.isEmpty
            ? attendees + s.candidates.prefix(2).map { resolve($0.0) }   // ältere Transkripte: „Kim“ → „Kim Beispiel“
            : (known + attendees).filter { n in
                n.range(of: typed, options: opts.union(.anchored)) != nil || n.range(of: " " + typed, options: opts) != nil }
        let shown = Array(NSOrderedSet(array: pool).array as! [String]).prefix(6)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                TextField(s.candidates.first.map { "\($0.0)? (\(String(format: "%.2f", $0.1)))" } ?? "Name",
                          text: Binding(get: { names[s.letter] ?? "" }, set: { names[s.letter] = $0 }))
                    .textFieldStyle(.roundedBorder).font(.caption)
                    .onSubmit { submit(s) }
                Button("Benennen") { submit(s) }.controlSize(.small)
                Button { editing.remove(s.letter); names[s.letter] = nil } label: { Image(systemName: "xmark.circle") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary).help("Abbrechen")
            }
            if !shown.isEmpty {
                FlowRow(spacing: 4) {
                    ForEach(Array(shown), id: \.self) { n in
                        chip(n, icon: known.contains(n) ? "person.wave.2" : "calendar", s)
                    }
                }
            }
        }
        .padding(.leading, 18)
        .task { if jobs.knownNames.isEmpty { await jobs.loadNames() } }
    }

    private func chip(_ name: String, icon: String, _ s: Speaker) -> some View {
        Button { names[s.letter] = name; submit(s) } label: {
            Label(name, systemImage: icon).font(.caption).lineLimit(1)
        }
        .buttonStyle(.bordered).controlSize(.small)
        .help(icon == "calendar" ? "Teilnehmer laut Kalender" : "Bekannte Stimme – wird mit ihr verknüpft")
    }

    private func submit(_ s: Speaker) {
        var n = (names[s.letter] ?? "").trimmingCharacters(in: .whitespaces)
        if n.isEmpty, s.status == "vermutlich", let c = s.candidates.first { n = c.0 }   // leer = Vorschlag übernehmen
        guard !n.isEmpty else { return }
        editing.remove(s.letter); names[s.letter] = nil
        Task { await jobs.name(job, letter: s.letter, name: n) }
    }
}
