import AppKit
import Foundation
import UserNotifications

/// Ruft den Python-Kern auf (`transcriber transcribe`). Fortschritt kommt nicht aus der Prozessausgabe, sondern aus den
/// Statusdateien unter ~/.local/share/transcriber/jobs/ – so erscheinen auch Aufträge von Wächter, CLI und MCP.
/// Fehler der App zum Nachlesen: ~/.local/share/transcriber/app.log
func appLog(_ msg: String) {
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(msg)\n"
    let url = Core.data.appendingPathComponent("app.log")
    if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
    else { try? line.write(to: url, atomically: true, encoding: .utf8) }
}

enum Core {
    static let data = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/transcriber")
    static let exe = data.appendingPathComponent("venvs/app/bin/transcriber")
    static let jobsDir = data.appendingPathComponent("jobs")
    /// Alle Sprachen, die Whisper kennt (wie transcriber/asr.py), mit deutschen Namen von macOS, alphabetisch.
    static let allLanguages: [(String, String)] = ("en zh de es ru ko fr ja pt tr pl ca nl ar sv it id hi fi vi he uk el ms cs ro da hu ta no th ur hr bg lt "
        + "la mi ml cy sk te fa lv bn sr az sl kn et mk br eu is hy ne mn bs kk sq sw gl mr pa si km sn yo so af "
        + "oc ka be tg sd gu am yi lo uz fo ht ps tk nn mt sa lb my bo tl mg as tt haw ln ha ba jw su yue")
        .split(separator: " ").map { c in
            let code = String(c)
            return (code, Locale(identifier: "de").localizedString(forLanguageCode: code == "jw" ? "jv" : code) ?? code)
        }
        .sorted { $0.1.localizedStandardCompare($1.1) == .orderedAscending }
    /// Welche davon im Panel zur Auswahl stehen (UserDefaults „languages“, Codes mit Komma).
    static let defaultLanguages = "de,en,es,fr"
    static func languages(_ enabled: String) -> [(String, String)] {
        let on = Set(enabled.split(separator: ",").map(String.init))
        return allLanguages.filter { on.contains($0.0) }
    }

    static func process(_ args: [String]) -> Process {
        let p = Process()
        p.executableURL = exe
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        // ffmpeg: vom Installer unter DATA/bin, sonst Homebrew; ein Finder-Start hat beides nicht im PATH
        env["PATH"] = data.appendingPathComponent("bin").path + ":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        p.environment = env
        return p
    }

    /// Kurzer Aufruf (benennen, bestätigen); liefert Erfolg und Ausgabe.
    static func run(_ args: [String]) async -> (Bool, String) {
        await withCheckedContinuation { cont in
            let p = process(args)
            let out = Pipe(); p.standardOutput = out; p.standardError = out
            p.terminationHandler = { pr in
                let s = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                cont.resume(returning: (pr.terminationStatus == 0, s))
            }
            do { try p.run() } catch { cont.resume(returning: (false, error.localizedDescription)) }
        }
    }
}

struct Speaker: Identifiable {
    var id: String { letter }
    let letter: String
    let display: String
    let status: String
    let score: Double?
    let speechMin: Double
    let candidates: [(String, Double)]
    var needsName: Bool { status == "unbekannt" || status == "vermutlich" }
}

@MainActor
final class Job: ObservableObject, Identifiable {
    enum State: String { case running, done, failed, aborted }
    let id: String            // Name der Statusdatei
    var source: URL
    let started: Date
    @Published var state: State = .running
    @Published var progress: Double = 0
    @Published var message = ""
    @Published var speakers: [Speaker] = []
    @Published var mdURL: URL?
    @Published var jsonURL: URL?
    @Published var error: String?
    @Published var attendees: [String] = []      // Kalender: andere Teilnehmer (Vorschläge beim Benennen)
    @Published var duration: Double = 0

    init(id: String, source: URL, started: Date) { self.id = id; self.source = source; self.started = started }

    func loadSpeakers() {
        guard let j = jsonURL, let d = try? Data(contentsOf: j),
              let doc = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let sp = doc["speakers"] as? [[String: Any]] else { return }
        duration = doc["duration"] as? Double ?? 0
        attendees = ((doc["event"] as? [String: Any])?["attendees"] as? [[String: Any]] ?? []).compactMap { a in
            (a["me"] as? Bool ?? false) || a["status"] as? String == "abgesagt" ? nil : a["name"] as? String
        }
        speakers = sp.map { s in
            let cands = (s["candidates"] as? [[Any]] ?? []).compactMap { c -> (String, Double)? in
                guard c.count == 2, let n = c[0] as? String, let v = c[1] as? Double else { return nil }
                return (n, v)
            }
            return Speaker(letter: s["letter"] as? String ?? "?", display: s["display"] as? String ?? "?",
                           status: s["status"] as? String ?? "", score: s["score"] as? Double,
                           speechMin: (s["speech_s"] as? Double ?? 0) / 60, candidates: cands)
        }.sorted { $0.speechMin > $1.speechMin }
    }
}

@MainActor
final class JobManager: ObservableObject {
    @Published var jobs: [Job] = []
    @Published var launchError: String?
    /// Namen aus der Stimmdatenbank – Vorschläge beim Benennen, damit nicht aus „Bjorn“ eine zweite Person wird.
    @Published var knownNames: [String] = []
    private var timer: Timer?
    private var hiddenBefore: Double { UserDefaults.standard.double(forKey: "hiddenBefore") }
    private var firstScan = true

    init() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.scan() }
        }
        RunLoop.main.add(t, forMode: .common)   // .common: läuft auch, solange das Menüleistenfenster offen ist
        timer = t
        scan()
    }

    var running: [Job] { jobs.filter { $0.state == .running } }

    /// Gesamtfortschritt für die Menüleiste (nil = nichts läuft).
    var overallProgress: Double? {
        let r = running
        return r.isEmpty ? nil : r.map(\.progress).reduce(0, +) / Double(r.count)
    }

    func add(_ url: URL, language: String) {
        launchError = nil
        let p = Core.process(["transcribe", url.path, "--language", language, "--progress", "json"])
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { launchError = "Kern nicht startbar: \(error.localizedDescription) (\(Core.exe.path))"; appLog(launchError!) }
    }

    /// Einzelnen Eintrag ausblenden (nur aus der Liste – Dateien bleiben).
    func hide(_ job: Job) {
        var h = Set(UserDefaults.standard.stringArray(forKey: "hiddenJobs") ?? [])
        h.insert(job.id)
        UserDefaults.standard.set(Array(h), forKey: "hiddenJobs")
        jobs.removeAll { $0.id == job.id }
    }

    func clearFinished() {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "hiddenBefore")
        jobs.removeAll { $0.state != .running }
    }

    private func scan() {
        let files = (try? FileManager.default.contentsOfDirectory(at: Core.jobsDir, includingPropertiesForKeys: nil)) ?? []
        var seen = Set<String>()
        let hidden = Set(UserDefaults.standard.stringArray(forKey: "hiddenJobs") ?? [])
        for f in files where f.pathExtension == "json" {
            guard let d = try? Data(contentsOf: f), let s = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let src = s["source"] as? String, let started = s["started"] as? Double else { continue }
            let id = f.lastPathComponent
            var state = Job.State(rawValue: s["state"] as? String ?? "") ?? .running
            if state == .running, let pid = s["pid"] as? Int32, kill(pid, 0) != 0 { state = .aborted }   // Prozess weg
            if state != .running && (started < hiddenBefore || hidden.contains(id)) { continue }
            if state != .running && Date().timeIntervalSince1970 - started > 86400 { continue }  // nur letzte 24 h
            seen.insert(id)
            let job = jobs.first { $0.id == id } ?? {
                let j = Job(id: id, source: URL(fileURLWithPath: src), started: Date(timeIntervalSince1970: started))
                jobs.append(j); return j
            }()
            job.progress = s["progress"] as? Double ?? 0
            job.message = s["message"] as? String ?? ""
            if job.state != state {
                let wasRunning = job.state == .running
                job.state = state
                if state == .done, let r = s["result"] as? [String: String] {
                    job.mdURL = r["md"].map { URL(fileURLWithPath: $0) }
                    job.jsonURL = r["json"].map { URL(fileURLWithPath: $0) }
                    job.loadSpeakers()
                }
                if state == .failed { job.error = s["error"] as? String }
                if state == .aborted { job.error = "abgebrochen (Prozess beendet)" }
                if wasRunning && !firstScan {
                    // Fertige App-Aufnahme mit Standardnamen: erst sprechend benennen, dann melden (Mitteilung mit neuem Namen).
                    if state == .done, let j = job.jsonURL, RecordingTitle.defaultStamp(job.source) != nil {
                        job.message = "Benenne …"
                        Task {
                            if let p = await RecordingTitle.apply(source: job.source, json: j) {
                                if let s = p["source"] { job.source = URL(fileURLWithPath: s) }
                                job.mdURL = p["md"].map { URL(fileURLWithPath: $0) }
                                job.jsonURL = p["json"].map { URL(fileURLWithPath: $0) }
                            }
                            notify(job)
                        }
                    } else {
                        notify(job)
                    }
                }
            } else if state == .done && job.jsonURL == nil, let r = s["result"] as? [String: String] {
                job.mdURL = r["md"].map { URL(fileURLWithPath: $0) }
                job.jsonURL = r["json"].map { URL(fileURLWithPath: $0) }
                job.loadSpeakers()
            }
        }
        jobs.removeAll { !seen.contains($0.id) }
        let existing = Set(files.map(\.lastPathComponent))   // Ausblendliste klein halten
        if hidden.contains(where: { !existing.contains($0) }) {
            UserDefaults.standard.set(hidden.filter { existing.contains($0) }.sorted(), forKey: "hiddenJobs")
        }
        jobs.sort { $0.started > $1.started }
        firstScan = false
    }

    private func notify(_ job: Job) {
        let c = UNMutableNotificationContent()
        c.title = job.state == .done ? "Transkript fertig" : "Transkription fehlgeschlagen"
        let open = job.speakers.filter(\.needsName).count
        c.body = job.source.lastPathComponent + (job.state == .done && open > 0 ? " · \(open) Stimme(n) zum Benennen" : "")
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: job.id, content: c, trigger: nil))
    }

    func name(_ job: Job, letter: String, name: String) async {
        guard let j = job.jsonURL else { return }
        let (ok, out) = await Core.run(["name", j.path, letter, name])
        if ok { job.loadSpeakers(); await loadNames() } else { job.error = out }
    }

    func loadNames() async {
        let (ok, out) = await Core.run(["speakers", "check", "--json"])
        guard ok, let line = out.split(separator: "\n").last, let d = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return }
        knownNames = obj.keys.sorted { $0.localizedCompare($1) == .orderedAscending }
    }

    func confirm(_ job: Job) async {
        guard let j = job.jsonURL else { return }
        let (ok, out) = await Core.run(["confirm", j.path])
        if ok { job.loadSpeakers() } else { job.error = out }
    }
}
