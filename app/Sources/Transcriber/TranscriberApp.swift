import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

@main
struct TranscriberApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var recorder = Recorder()
    @StateObject private var jobs = JobManager()
    @StateObject private var dictation = Dictation()
    @StateObject private var calls = CallDetector()
    @StateObject private var updates = UpdateCheck()
    private let uiTest = CommandLine.arguments.contains("--ui-test")

    init() {
        if CommandLine.arguments.contains("--vp-test") { VPTest.run(); exit(0) }
        if CommandLine.arguments.contains("--latency-test") { VPTest.latency(); exit(0) }
        if CommandLine.arguments.contains("--tap-test") { VPTest.tap(); exit(0) }
        if CommandLine.arguments.contains("--calendar-test") { Task { await VPTest.calendar(); exit(0) } }
        if CommandLine.arguments.contains("--cleanup-test") { Task { await VPTest.cleanup(); exit(0) } }
        if let i = CommandLine.arguments.firstIndex(of: "--gap-test"), i + 1 < CommandLine.arguments.count {
            let folder = URL(fileURLWithPath: CommandLine.arguments[i + 1])
            let gap = CommandLine.arguments.firstIndex(of: "--gap").flatMap { Double(CommandLine.arguments[$0 + 1]) } ?? 2.5
            Task { await VPTest.gap(folder, voiceProcessing: CommandLine.arguments.contains("--vp"), gap: gap); exit(0) }
        }
        if let i = CommandLine.arguments.firstIndex(of: "--mic-switch-test"), i + 1 < CommandLine.arguments.count {
            let folder = URL(fileURLWithPath: CommandLine.arguments[i + 1])
            Task { await VPTest.micSwitch(folder); exit(0) }
        }
        if CommandLine.arguments.contains("--report-test") {   // Fehlerbericht erstellen, ohne Mail
            Task { @MainActor in
                let r = await BugReport.create(description: "Selbsttest", redact: true)
                appLog("Report-Test: \(r.url?.path ?? "FEHLER \(r.error ?? "?")")")
                exit(0)
            }
        }
        if let i = CommandLine.arguments.firstIndex(of: "--title-test") {
            let files = CommandLine.arguments[(i + 1)...].map { URL(fileURLWithPath: $0) }
            Task { await VPTest.titles(files); exit(0) }
        }
    }

    var body: some Scene {
        MenuBarExtra {
            PanelView().environmentObject(recorder).environmentObject(jobs).environmentObject(dictation).environmentObject(calls)
                .environmentObject(updates)
        } label: {
            MenuLabel().environmentObject(recorder).environmentObject(jobs).environmentObject(dictation)
                .onAppear {
                    let r = recorder, j = jobs
                    appDelegate.recorder = r; appDelegate.jobs = j
                    dictation.micBusy = { r.isRecording }
                    calls.isRecording = { r.isRecording }
                    let c = calls
                    calls.startRecording = { Task { try? await Control.start(r, callMic: c.micUID) } }
                    calls.currentMic = { Control.callMic }
                    calls.switchMic = { uid in Control.switchMic(r, uid) }
                    calls.stopRecording = { Task { await Control.stop(r, j) } }
                }
        }
        .menuBarExtraStyle(.window)
        .onChange(of: uiTest, initial: true) { _, on in
            guard on else { return }
            Task { await VPTest.ui(recorder: recorder, jobs: jobs, dictation: dictation, calls: calls, updates: updates); exit(0) }
        }

        Window("Fehler melden", id: "report") { ReportView() }
            .windowResizability(.contentSize)
        Window("Einstellungen", id: "settings") {
            SettingsView().environmentObject(dictation).environmentObject(calls).environmentObject(updates)
        }
        .windowResizability(.contentSize)
    }
}

/// Datenordner ~/Transcriber (bis 0.5 ~/Transkription – der Installer benennt ihn einmalig um).
/// Beenden (Panel, ⌘Q, Abmelden, Update per Installer) schließt eine laufende Aufnahme erst sauber ab – sonst fehlt der
/// Dateikopf (moov) und die Datei ist unlesbar (passiert 2026-10-10 beim Neustart der App während einer Aufnahme).
final class AppDelegate: NSObject, NSApplicationDelegate {
    var recorder: Recorder?
    var jobs: JobManager?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let r = recorder, let j = jobs, r.isRecording else { return .terminateNow }
        appLog("Beenden während der Aufnahme: Aufnahme wird erst abgeschlossen")
        Task { @MainActor in
            await Control.stop(r, j)
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

let watchDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Transcriber")
/// Aufnahmen: „Aufnahmen“ oder „Recordings“ nach der Systemsprache beim ersten Anlegen; ein vorhandener bleibt,
/// auch wenn die Sprache später wechselt (sonst lägen Aufnahmen in zwei Ordnern).
var recordingsDir: URL {
    for n in ["Aufnahmen", "Recordings"] where FileManager.default.fileExists(atPath: watchDir.appendingPathComponent(n).path) {
        return watchDir.appendingPathComponent(n)
    }
    return watchDir.appendingPathComponent(Locale.preferredLanguages.first?.hasPrefix("de") == true ? "Aufnahmen" : "Recordings")
}

/// Aufnahme starten/stoppen mit den Einstellungen aus dem Panel – vom Knopf und von der Call-Erkennung genutzt.
@MainActor
enum Control {
    /// Termin der laufenden Aufnahme (beim Start ermittelt, beim Stopp neben die Datei gelegt).
    private static var event: [String: Any]?
    /// Call-Aufnahme: Mikrofon der Call-App (UID); nil = Mikrofon aus dem Panel.
    static var callMic: String?

    /// callMic: bei Call-Aufnahmen das Mikrofon der Call-App statt der Panel-Auswahl.
    static func start(_ recorder: Recorder, callMic: String? = nil) async throws {
        guard !recorder.isRecording, !recorder.isStarting else { return }
        recorder.isStarting = true
        defer { recorder.isStarting = false }
        event = nil
        if CalendarContext.enabled {
            Task {
                guard await CalendarContext.access(), let e = CalendarContext.current() else { return }
                event = CalendarContext.info(e)
                appLog("Termin zur Aufnahme: \(e.title ?? "?") (\(e.attendees?.count ?? 0) Teilnehmer)")
            }
        }
        let d = UserDefaults.standard
        let mic = callMic ?? d.string(forKey: "micID") ?? ""
        Self.callMic = callMic
        recorder.warning = nil
        try await recorder.start(deviceID: mic.isEmpty ? nil : mic, systemAudio: d.object(forKey: "systemAudio") as? Bool ?? true,
                                 voiceProcessing: d.object(forKey: "voiceProcessing") as? Bool ?? true,
                                 folder: recordingsDir)
    }

    static func switchMic(_ recorder: Recorder, _ uid: String) {
        guard recorder.isRecording else { return }
        let vp = UserDefaults.standard.object(forKey: "voiceProcessing") as? Bool ?? true
        do { try recorder.switchMic(deviceID: uid, voiceProcessing: vp); callMic = uid }
        catch { appLog("Mikrofonwechsel fehlgeschlagen: \(error)"); callMic = uid }   // nicht jede 2 s erneut versuchen
    }

    static func stop(_ recorder: Recorder, _ jobs: JobManager) async {
        guard recorder.isRecording else { return }
        callMic = nil
        let d = UserDefaults.standard
        let url = await recorder.stop()
        if let url, let e = event { CalendarContext.write(e, next: url) }
        event = nil
        if let url, d.object(forKey: "autoTranscribe") as? Bool ?? true {
            jobs.add(url, language: d.string(forKey: "language") ?? "de", speakers: Int(d.string(forKey: "nextSpeakers") ?? "") ?? 0)
            d.set("0", forKey: "nextSpeakers")
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
    @EnvironmentObject var updates: UpdateCheck
    @AppStorage("dictation") private var dictationOn = false
    @AppStorage("dictationKey") private var dictationKey = "rcmd"
    @AppStorage("dictationCleanKey") private var dictationCleanKey = "ropt"
    @AppStorage("micID") private var micID = ""
    @AppStorage("language") private var language = "de"
    @AppStorage("languages") private var languages = Core.defaultLanguages
    @AppStorage("nextSpeakers") private var nextSpeakers = "0"   // nur für die nächste Aufnahme/Datei, dann wieder 0
    @State private var listHeight: CGFloat = 0
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
                                Label(recorder.isStarting ? "Startet …" : recorder.isRecording ? "Aufnahme beenden"
                                      : calls.current != nil ? "Call aufnehmen" : "Aufnahme starten",
                                      systemImage: recorder.isStarting ? "hourglass" : recorder.isRecording ? "stop.circle.fill"
                                      : calls.current != nil ? "phone.circle" : "record.circle")
                                    .frame(maxWidth: .infinity)
                            }
                            .keyboardShortcut(.defaultAction)
                            .disabled(recorder.isStarting)
                            .tint(recorder.isRecording ? .red : .accentColor)
                            FillMenu(selection: $micID,
                                     options: [("", String(localized: "Systemstandard"))] + mics.map { ($0.uniqueID, $0.localizedName) })
                            .frame(width: 190)
                            .disabled(recorder.isRecording || recorder.isStarting)
                            .onAppear { mics = Recorder.microphones() }
                            .help("Mikrofon")
                        }
                        GridRow {
                            Button { pickFiles() } label: {
                                Label("Datei transkribieren …", systemImage: "doc.badge.plus").frame(maxWidth: .infinity)
                            }
                            HStack(spacing: 6) {
                                FillMenu(selection: $language, options: Core.languages(languages))
                                    .help("Sprache für Aufnahmen, Dateien und Diktat")
                                FillMenu(selection: $nextSpeakers, options: Core.speakerCounts, icon: "person.2",
                                         compact: { $0 == "0" ? String(localized: "Auto") : $0 })
                                    .frame(width: 86)
                                    .help("Personen in der nächsten Aufnahme oder Datei – Auto erkennt selbst; danach wieder Auto")
                            }
                            .frame(width: 190)
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
                        Group {
                            if let m = calls.micName { Label("Call in \(c) erkannt · Mikrofon wie im Call: \(m)", systemImage: "phone.fill") }
                            else { Label("Call in \(c) erkannt", systemImage: "phone.fill") }
                        }
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    if let w = recorder.warning { Text(w).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
                    Divider()
                    dictationLine
                }
                .padding(6)
            }

            if !jobs.untranscribed.isEmpty { untranscribedLine }

            if !jobs.jobs.isEmpty {
                HStack {
                    Text("Transkriptionen").font(.subheadline.weight(.semibold))
                    Spacer()
                    if jobs.jobs.contains(where: { $0.state != .running }) {
                        Button("Erledigte ausblenden") { jobs.clearFinished() }.controlSize(.small).buttonStyle(.link)
                    }
                }
                // Eine ScrollView schrumpft im selbst bemessenden Menüleistenfenster auf Höhe 0 – deshalb feste Höhe:
                // so hoch wie der Inhalt, höchstens so, dass Kopf und Fußzeile (Beenden) auf dem Bildschirm bleiben.
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) { ForEach(jobs.jobs) { JobRow(job: $0) } }
                        .background(GeometryReader { g in
                            Color.clear.onAppear { listHeight = g.size.height }
                                .onChange(of: g.size.height) { _, h in listHeight = h }
                        })
                }
                .frame(height: min(listHeight, maxListHeight))
            }
            if let e = error ?? jobs.launchError { Text(e).font(.caption).foregroundStyle(.red) }
            updateLine
            Divider()
            toolbar
        }
        .padding(14)
        .frame(width: 440)
    }

    /// Leiste unten, bündig mit den Kästen darüber (Variante „E3“ aus den Mockups, Björn 2026-10-14): Ordner und
    /// Einstellungen mit Text, Fehler melden als Käfer, Beenden rechts. Mit Text bei allen vier passten de/en nicht.
    private var toolbar: some View {
        HStack(spacing: 6) {
            Button { NSWorkspace.shared.open(watchDir) } label: { Label("Ordner", systemImage: "folder") }.fixedSize()
            Button { openWindow(id: "settings"); NSApp.activate(ignoringOtherApps: true) } label: { Label("Einstellungen", systemImage: "gearshape") }
                .keyboardShortcut(",").fixedSize()
            Spacer(minLength: 0)
            Button { openWindow(id: "report"); NSApp.activate(ignoringOtherApps: true) } label: { Image(systemName: "ladybug") }
                .help("Fehler melden …")
            Button { NSApp.terminate(nil) } label: { Label("Beenden", systemImage: "power") }.fixedSize()
        }
        .controlSize(.small)
    }


    /// Aufnahmen ohne Transkript (Transkribieren war aus oder der Start scheiterte): nur auf Klick starten.
    private var untranscribedLine: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.badge.clock").foregroundStyle(.orange)
            Text(jobs.untranscribed.count == 1 ? String(localized: "1 Aufnahme ohne Transkript")
                                                : String(localized: "\(jobs.untranscribed.count) Aufnahmen ohne Transkript"))
                .help(jobs.untranscribed.map(\.lastPathComponent).joined(separator: "\n"))
            Spacer(minLength: 4)
            Button("Transkribieren") { jobs.transcribeUntranscribed(language: language) }.controlSize(.small)
            Button("Ausblenden") { jobs.ignoreUntranscribed() }.controlSize(.small).buttonStyle(.link)
        }
        .font(.caption)
    }

    /// Bildschirmhöhe minus Kopf, Aufnahmebereich, Update-Hinweis und Fußzeile (großzügig geschätzt).
    private var maxListHeight: CGFloat { max(200, (NSScreen.main?.visibleFrame.height ?? 800) - 420) }

    private var status: String {
        if recorder.isRecording { return String(localized: "Aufnahme \(timeString(recorder.elapsed))") }
        if let p = jobs.overallProgress { return String(localized: "Transkribiere \(Int(p * 100)) %") }
        return String(localized: "Bereit")
    }

    /// Update: beim ersten Öffnen einmal fragen (Website und Datenschutzerklärung versprechen „offline“ – also nur mit
    /// Zustimmung), danach nur noch eine Zeile, wenn eine neuere Version da ist.
    @ViewBuilder private var updateLine: some View {
        if updates.enabled == nil {
            VStack(alignment: .leading, spacing: 6) {
                Text("Einmal täglich nach neuen Versionen suchen?").font(.callout.weight(.medium))
                Text("Fragt nur die aktuelle Versionsnummer bei transcriber.teconomix.net ab – nichts über dich oder deine Aufnahmen. Später änderbar in den Einstellungen.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Ja, suchen") { updates.set(true) }
                    Button("Nein") { updates.set(false) }
                }
                .controlSize(.small)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.1)))
        } else if let v = updates.available {
            HStack(spacing: 6) {
                Image(systemName: "arrow.down.circle").foregroundStyle(.tint)
                Text("Version \(v) verfügbar")
                Spacer()
                Button("Aktualisieren …") { UpdateCheck.openInstructions() }.controlSize(.small)
            }
            .font(.caption)
        }
    }

    /// Diktat im Panel: Hinweiszeile (welche Tasten, rot/orange, wenn etwas fehlt) mit Schalter – so lassen sich die
    /// Tasten freigeben, ohne in die Einstellungen zu gehen.
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
                Group {
                    if dictationCleanKey == "off" { Text("Diktat: \(label(dictationKey))") }
                    else { Text("Diktat: \(label(dictationKey)) · mit KI: \(label(dictationCleanKey))") }
                }
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Toggle("Diktat", isOn: Binding(get: { dictationOn }, set: { dictation.setEnabled($0) }))
                .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                .help(dictationOn ? "Diktat ausschalten (Tasten wieder frei)" : "Diktat einschalten")
        }
        .font(.caption)
    }

    private func toggleRecording() {
        error = nil
        guard !recorder.isStarting else { return }
        Task {
            if recorder.isRecording {
                await Control.stop(recorder, jobs)
            } else if calls.current != nil {
                calls.recordCall()                      // Mikrofon wie im Call, endet mit dem Call
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
        if p.runModal() == .OK {
            for u in p.urls { jobs.add(u, language: language, speakers: Int(nextSpeakers) ?? 0) }
            nextSpeakers = "0"
        }
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
    var icon: String?
    var compact: ((String) -> String)?          // kürzere Beschriftung im Knopf als im Menü

    var body: some View {
        Button(action: show) {
            HStack(spacing: 4) {
                if let icon { Image(systemName: icon).foregroundStyle(.secondary) }
                Text(compact?(selection) ?? options.first { $0.0 == selection }?.1 ?? options.first?.1 ?? "").lineLimit(1)
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
    @State private var newTitle: String?              // Umbenennen: Feld offen, solange nicht nil
    @Environment(\.openWindow) private var openWindow

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
            if let t = newTitle { renameEditor(t) }
            switch job.state {
            case .running:
                ProgressView(value: job.progress) { Text(job.message).font(.caption) }
            case .failed, .aborted:
                Text(job.error ?? String(localized: "fehlgeschlagen")).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                Button("Fehler melden …") {
                    ReportDraft.shared.text = String(localized: "Transkription fehlgeschlagen: \(job.error ?? "?")") + "\n\n"
                    openWindow(id: "report"); NSApp.activate(ignoringOtherApps: true)
                }
                .buttonStyle(.link).font(.caption)
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
            Text("·").foregroundStyle(.tertiary)
            Button("Umbenennen") { newTitle = job.source.deletingPathExtension().lastPathComponent }.buttonStyle(.link)
                .help("Aufnahme und Transkript umbenennen – im Finder umbenannt würde die Aufnahme neu transkribiert")
            Text("·").foregroundStyle(.tertiary)
            Button("Neu auswerten …") { rerunMenu() }.buttonStyle(.link)
                .help("Namen neu zuordnen oder Sprecher neu trennen")
        }
        .font(.caption)
    }

    private func renameEditor(_ t: String) -> some View {
        HStack(spacing: 6) {
            TextField("Neuer Name", text: Binding(get: { newTitle ?? t }, set: { newTitle = $0 }))
                .textFieldStyle(.roundedBorder).font(.caption)
                .onSubmit { submitRename() }
            Button("Umbenennen") { submitRename() }.controlSize(.small)
            Button { newTitle = nil } label: { Image(systemName: "xmark.circle") }
                .buttonStyle(.borderless).foregroundStyle(.secondary).help("Abbrechen")
        }
    }

    private func submitRename() {
        let n = (newTitle ?? "").trimmingCharacters(in: .whitespaces)
        newTitle = nil
        guard !n.isEmpty, n != job.source.deletingPathExtension().lastPathComponent else { return }
        Task { job.error = await jobs.rename(job, to: n) }
    }

    /// Namen neu zuordnen (nur Abgleich mit der Datenbank, sofort) oder Sprecher neu trennen mit fester Personenzahl
    /// (Sprechertrennung neu, Spracherkennung aus dem Zwischenspeicher). Benennung nach Rückfrage 2026-10-12:
    /// „Stimmen neu erkennen“ vs. „Neu auswerten mit“ war nicht unterscheidbar.
    private func rerunMenu() {
        let menu = NSMenu()
        let names = ClosureMenuItem(title: String(localized: "Namen neu zuordnen")) { Task { await jobs.recheck(job) } }
        let hint = String(localized: "Nur neuer Abgleich mit Stimmdatenbank")
        if #available(macOS 14.4, *) { names.subtitle = hint } else { names.toolTip = hint }
        menu.addItem(names)
        menu.addItem(.separator())
        let head = NSMenuItem(title: String(localized: "Sprecher neu trennen:"), action: nil, keyEquivalent: "")
        head.isEnabled = false
        menu.addItem(head)
        for (id, title) in [("0", String(localized: "Automatisch"))] + Core.speakerCounts.dropFirst() + (7...10).map({ (String($0), String(localized: "\($0) Personen")) }) {
            menu.addItem(ClosureMenuItem(title: title) { jobs.rerun(job, speakers: Int(id) ?? 0) })
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
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
                    Text(LocalizedStringKey(s.status)).font(.caption).foregroundStyle(.tertiary)   // Statuscode aus dem Kern
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
