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
    /// Sprache der Oberfläche („de“ oder „en“, folgt macOS bzw. der Einstellung je App); geht als TRANSCRIBER_UI_LANG
    /// an den Kern, damit Transkript-Kopf, Fortschritt und Meldungen dieselbe Sprache sprechen.
    static let uiLanguage = Bundle.main.preferredLocalizations.first == "en" ? "en" : "de"
    /// Alle Sprachen, die Whisper kennt (wie transcriber/asr.py), mit Namen von macOS in der Oberflächensprache, alphabetisch.
    static let allLanguages: [(String, String)] = ("en zh de es ru ko fr ja pt tr pl ca nl ar sv it id hi fi vi he uk el ms cs ro da hu ta no th ur hr bg lt "
        + "la mi ml cy sk te fa lv bn sr az sl kn et mk br eu is hy ne mn bs kk sq sw gl mr pa si km sn yo so af "
        + "oc ka be tg sd gu am yi lo uz fo ht ps tk nn mt sa lb my bo tl mg as tt haw ln ha ba jw su yue")
        .split(separator: " ").map { c in
            let code = String(c)
            return (code, Locale(identifier: uiLanguage).localizedString(forLanguageCode: code == "jw" ? "jv" : code) ?? code)
        }
        .sorted { $0.1.localizedStandardCompare($1.1) == .orderedAscending }
    /// Personenzahl im Panel: „0“ = automatisch, sonst genau so viele (an pyannote als num_speakers).
    static let speakerCounts: [(String, String)] = [("0", String(localized: "Automatisch")), ("1", String(localized: "1 Person"))]
        + (2...6).map { (String($0), String(localized: "\($0) Personen")) }
    /// Lesbares Transkript als „txt“ (reiner Text, Standard) oder „md“ (Markdown). Steht in config.json (text_format), damit auch
    /// Ordnerwächter, Kommandozeile und MCP es kennen; die App liest und schreibt nur diesen einen Schlüssel.
    static var textFormat: String {
        get { (configJSON()["text_format"] as? String) == "md" ? "md" : "txt" }
        set {
            var cfg = configJSON()
            cfg["text_format"] = newValue == "md" ? "md" : "txt"
            guard let out = try? JSONSerialization.data(withJSONObject: cfg, options: [.prettyPrinted, .sortedKeys]) else { return }
            do {
                try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
                try out.write(to: data.appendingPathComponent("config.json"), options: .atomic)
            } catch { appLog("config.json nicht geschrieben: \(error.localizedDescription)") }
        }
    }
    private static func configJSON() -> [String: Any] {
        guard let d = try? Data(contentsOf: data.appendingPathComponent("config.json")),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
        return o
    }
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
        env["TRANSCRIBER_UI_LANG"] = uiLanguage
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
    @Published var audioGone = false              // Aufnahme gelöscht (Nur Aufnahme, 30-Tage-Regel, Finder), Transkript da
    var language = "de"                          // Sprache dieses Transkripts (für „Neu auswerten“)

    init(id: String, source: URL, started: Date) { self.id = id; self.source = source; self.started = started }

    func loadSpeakers() {
        guard let j = jsonURL, let d = try? Data(contentsOf: j),
              let doc = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let sp = doc["speakers"] as? [[String: Any]] else { return }
        duration = doc["duration"] as? Double ?? 0
        language = doc["language"] as? String ?? language
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
    /// Aufnahmen im Aufnahmeordner ohne Transkript (der Wächter lässt diesen Ordner aus – die App startet dort selbst).
    /// Entsteht, wenn „Transkribieren“ aus ist oder ein Start scheiterte (Absturz zwischen Stopp und Auftrag).
    @Published var untranscribed: [URL] = []
    private var ticks = 0
    /// Nur Demo-Bild (--ui-test --demo): Liste nicht aus den Statusdateien neu einlesen.
    var frozen = false
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
        // Aufräumen: nach Löschen im Finder, und Aufnahmen nach 30 Tagen (Einstellung) – kurz nach dem Start, dann alle 10 min.
        let c = Timer(timeInterval: 600, repeats: true) { [weak self] _ in Task { @MainActor in await self?.cleanup() } }
        RunLoop.main.add(c, forMode: .common)
        cleanupTimer = c
        Task { try? await Task.sleep(nanoseconds: 20_000_000_000); await cleanup() }
    }
    private var cleanupTimer: Timer?

    /// `transcriber cleanup`: im Finder Gelöschtes aufräumen (Zwischenspeicher, Stimmdatenbank, Eintrag); mit der
    /// Einstellung „Aufnahmen nach 30 Tagen löschen“ auch das Audio alter, fertig transkribierter Aufnahmen.
    func cleanup() async {
        guard !frozen else { return }
        let days = UserDefaults.standard.bool(forKey: "audioRetention") ? ["--audio-days", "30"] : []
        let (ok, out) = await Core.run(["cleanup", "--json"] + days)
        guard ok, let line = out.split(separator: "\n").last, let d = line.data(using: .utf8),
              let r = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
            appLog("Aufräumen fehlgeschlagen: \(out.suffix(300))"); return
        }
        let forgotten = r["forgotten"] as? Int ?? 0, audio = (r["audio_deleted"] as? [String])?.count ?? 0
        if forgotten > 0 || audio > 0 { appLog("Aufgeräumt: \(forgotten) im Finder gelöschte Aufnahmen, \(audio) Aufnahmen älter als 30 Tage") }
    }

    /// Löschen (`transcriber delete`): audioOnly = nur die Aufnahme, Transkript und Stimmen bleiben. Sonst alles; der
    /// Eintrag verschwindet mit seinen Statusdateien. Liefert nil bei Erfolg, sonst die Fehlermeldung.
    func delete(_ job: Job, audioOnly: Bool) async -> String? {
        let target = job.jsonURL ?? job.source
        let (ok, out) = await Core.run(["delete", target.path, "--json"] + (audioOnly ? ["--audio-only"] : []))
        guard ok else {
            appLog("Löschen fehlgeschlagen: \(out)")
            return out.split(separator: "\n").last.map(String.init) ?? String(localized: "Löschen fehlgeschlagen")
        }
        // Mit Namen: 2026-10-20 ließ sich sonst nicht nachvollziehen, welcher Eintrag gelöscht worden war.
        appLog((audioOnly ? "Aufnahme gelöscht, Transkript bleibt: " : "Aufnahme samt Transkript gelöscht: ") + job.source.lastPathComponent)
        if audioOnly { job.audioGone = true } else { jobs.removeAll { $0.id == job.id } }
        return nil
    }

    var running: [Job] { jobs.filter { $0.state == .running } }

    /// Gesamtfortschritt für die Menüleiste (nil = nichts läuft).
    var overallProgress: Double? {
        let r = running
        return r.isEmpty ? nil : r.map(\.progress).reduce(0, +) / Double(r.count)
    }

    /// speakers: genaue Personenzahl (0 = automatisch, Obergrenze aus Kalender bzw. 15).
    func add(_ url: URL, language: String, speakers: Int = 0) {
        launchError = nil
        let p = Core.process(["transcribe", url.path, "--language", language, "--progress", "json"]
                             + (speakers > 0 ? ["--speakers", String(speakers)] : []))
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { launchError = String(localized: "Kern nicht startbar: \(error.localizedDescription) (\(Core.exe.path))"); appLog(launchError!) }
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
        guard !frozen else { return }
        let files = (try? FileManager.default.contentsOfDirectory(at: Core.jobsDir, includingPropertiesForKeys: nil)) ?? []
        var seen = Set<String>()
        let hidden = Set(UserDefaults.standard.stringArray(forKey: "hiddenJobs") ?? [])
        let status: [(URL, [String: Any])] = files.filter { $0.pathExtension == "json" }.compactMap { f in
            guard let d = try? Data(contentsOf: f), let s = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
            return (f, s)
        }
        // Neuauswertung derselben Datei: nur der jüngste Lauf je Quelle. Ältere hier überspringen – nicht erst anlegen und
        // wieder entfernen, sonst gälten sie bei jedem Durchlauf als „gerade fertig“ (Mitteilung im Sekundentakt, 2026-10-12).
        var newest: [String: Double] = [:]
        for (_, s) in status { if let src = s["source"] as? String, let t = s["started"] as? Double { newest[src] = max(newest[src] ?? t, t) } }
        for (f, s) in status {
            guard let src = s["source"] as? String, let started = s["started"] as? Double else { continue }
            let id = f.lastPathComponent
            var state = Job.State(rawValue: s["state"] as? String ?? "") ?? .running
            if state == .running, let pid = s["pid"] as? Int32, kill(pid, 0) != 0 { state = .aborted }   // Prozess weg
            if state != .running && started < newest[src]! { continue }
            if state != .running && (started < hiddenBefore || hidden.contains(id)) { continue }
            if state != .running && Date().timeIntervalSince1970 - started > 86400 { continue }  // nur letzte 24 h
            seen.insert(id)
            let job = jobs.first { $0.id == id } ?? {
                let j = Job(id: id, source: URL(fileURLWithPath: src), started: Date(timeIntervalSince1970: started))
                jobs.append(j); return j
            }()
            job.progress = s["progress"] as? Double ?? 0
            job.message = s["message"] as? String ?? ""
            let gone = state == .done && !FileManager.default.fileExists(atPath: job.source.path)
            if job.audioGone != gone { job.audioGone = gone }
            if job.state != state {
                let wasRunning = job.state == .running
                job.state = state
                if state == .done, let r = s["result"] as? [String: String] {
                    job.mdURL = r["md"].map { URL(fileURLWithPath: $0) }
                    job.jsonURL = r["json"].map { URL(fileURLWithPath: $0) }
                    job.loadSpeakers()
                }
                if state == .failed { job.error = s["error"] as? String }
                if state == .aborted { job.error = String(localized: "abgebrochen (Prozess beendet)") }
                if wasRunning && !firstScan {
                    // Fertige App-Aufnahme mit Standardnamen: erst sprechend benennen, dann melden (Mitteilung mit neuem Namen).
                    if state == .done, let j = job.jsonURL, RecordingTitle.defaultStamp(job.source) != nil {
                        job.message = String(localized: "Benenne …")
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
        if ticks % 5 == 0 { findUntranscribed() }
        ticks += 1
    }

    private func findUntranscribed() {
        let fm = FileManager.default
        let ignored = Set(UserDefaults.standard.stringArray(forKey: "ignoredRecordings") ?? [])
        let busy = Set(running.map(\.source.path))
        let files = (try? fm.contentsOfDirectory(at: recordingsDir, includingPropertiesForKeys: [.contentModificationDateKey],
                                                 options: .skipsHiddenFiles)) ?? []   // laufende Aufnahme: „.name.m4a“
        let found = files.filter { f in
            let stem = f.deletingPathExtension()
            let modified = (try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return ["m4a", "mp3", "wav", "aac", "caf", "mp4", "mov"].contains(f.pathExtension.lowercased())
                && !ignored.contains(f.path) && !busy.contains(f.path)
                && Date().timeIntervalSince(modified) > 60                       // gerade beendet: Auftrag startet gleich
                && ["transcript.json", "lock", "error.txt"].allSatisfy { !fm.fileExists(atPath: stem.path + "." + $0) }
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        if found != untranscribed { untranscribed = found }
    }

    func transcribeUntranscribed(language: String) {
        for u in untranscribed { add(u, language: language) }
        untranscribed = []
    }

    func ignoreUntranscribed() {
        let d = UserDefaults.standard
        d.set(Array(Set(d.stringArray(forKey: "ignoredRecordings") ?? []).union(untranscribed.map(\.path))), forKey: "ignoredRecordings")
        untranscribed = []
    }

    private func notify(_ job: Job) {
        let c = UNMutableNotificationContent()
        c.title = job.state == .done ? String(localized: "Transkript fertig") : String(localized: "Transkription fehlgeschlagen")
        let open = job.speakers.filter(\.needsName).count
        c.body = job.source.lastPathComponent + (job.state == .done && open > 0 ? " · " + String(localized: "\(open) Stimme(n) zum Benennen") : "")
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

    /// Neu auswerten (andere Personenzahl): Der Kern nimmt Spracherkennung und Audio aus dem Zwischenspeicher, rechnet
    /// nur die Sprechertrennung neu und übernimmt eindeutige Bestätigungen. Der alte Eintrag weicht dem neuen Lauf.
    func rerun(_ job: Job, speakers: Int) {
        guard FileManager.default.fileExists(atPath: job.source.path) else {
            job.error = String(localized: "Audiodatei nicht gefunden"); return
        }
        hide(job)
        add(job.source, language: job.language, speakers: speakers)
    }

    /// Offene Stimmen neu mit der Stimmdatenbank abgleichen (Sekundenbruchteile, nichts wird neu gerechnet).
    func recheck(_ job: Job) async {
        guard let j = job.jsonURL else { return }
        let (ok, out) = await Core.run(["recheck", j.path])
        if ok { job.loadSpeakers() } else { job.error = out }
    }

    /// Aufnahme samt Transkript umbenennen (`transcriber rename`: Audio, .transcript.json, .md, .srt, .event.json,
    /// Stimmdatenbank, Statusdateien). Im Finder umbenannt fände der Wächter eine Datei ohne Transkript und
    /// transkribierte sie neu. Liefert nil bei Erfolg, sonst die Fehlermeldung.
    func rename(_ job: Job, to name: String) async -> String? {
        guard let j = job.jsonURL else { return String(localized: "Transkript nicht gefunden") }
        let (ok, out) = await Core.run(["rename", j.path, name, "--json"])
        guard ok, let line = out.split(separator: "\n").last, let d = line.data(using: .utf8),
              let p = try? JSONSerialization.jsonObject(with: d) as? [String: String] else {
            appLog("Umbenennen fehlgeschlagen: \(out)")
            return out.split(separator: "\n").last.map(String.init) ?? String(localized: "Umbenennen fehlgeschlagen")
        }
        if let s = p["source"] { job.source = URL(fileURLWithPath: s) }
        job.mdURL = p["md"].map { URL(fileURLWithPath: $0) }
        job.jsonURL = p["json"].map { URL(fileURLWithPath: $0) }
        return nil
    }

    func confirm(_ job: Job) async {
        guard let j = job.jsonURL else { return }
        let (ok, out) = await Core.run(["confirm", j.path])
        if ok { job.loadSpeakers() } else { job.error = out }
    }
}
