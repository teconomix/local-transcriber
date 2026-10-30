import Foundation

/// iPhone-Weg ohne Cloud: Audio, das per AirDrop am Mac ankommt (macOS legt es immer in `~/Downloads`), holt die App
/// nach `~/Transcriber/iPhone`. Erkannt am Quarantäne-Merkmal: AirDrop-Dateien tragen den Absender `sharingd`
/// (`0081;…;sharingd;…`, an echten AirDrop-Dateien geprüft 2026-10-24) – Browser-Downloads tragen den Browser.
/// Downloads ist ein geschützter Ordner: macOS fragt beim ersten Blick hinein. Deshalb schaut die App nur hinein, wenn die
/// Einstellung an ist – die Abfrage kommt beim Einschalten, nie vorher. Alles andere in Downloads bleibt unberührt, und nur
/// Dateien, die nach dem Einschalten angekommen sind (alte Sprachmemos im Ordner werden nicht eingesammelt).
enum AirDropInbox {
    static var enabled: Bool { UserDefaults.standard.bool(forKey: "airdropInbox") }
    /// Zeitpunkt des Einschaltens – ältere Dateien bleiben liegen.
    static var since: Double { UserDefaults.standard.double(forKey: "airdropInboxSince") }
    static var downloads: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
    }
    /// Nur Audio: ein per AirDrop geschicktes Video (Familienfilm) bleibt in Downloads – die Einstellung verspricht
    /// „nur Audiodateien“, und die 30-Tage-Löschung gilt unter ~/Transcriber auch für Videos.
    static let audioExt = ICloudInbox.ext.subtracting(["mp4", "mov", "m4v", "mkv", "webm"])
    private static var seen: [String: [Int]] = [:]

    /// Aus den Einstellungen: merkt den Zeitpunkt und schaut sofort hinein – das löst die Abfrage von macOS aus.
    static func setEnabled(_ on: Bool) {
        if on { UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "airdropInboxSince") }
        if on { ICloudInbox.queue.async { tick() } }
    }

    static func isAirDrop(_ f: URL) -> Bool {
        let n = getxattr(f.path, "com.apple.quarantine", nil, 0, 0, 0)
        guard n > 0 else { return false }
        var buf = [UInt8](repeating: 0, count: n)
        guard getxattr(f.path, "com.apple.quarantine", &buf, n, 0, 0) == n else { return false }
        return String(decoding: buf, as: UTF8.self).split(separator: ";").dropFirst(2).first == "sharingd"
    }

    /// Standardname „Aufnahme/Recording <Datum>“ für die Vorgabenamen von Sprachmemos („Neue Aufnahme 3“,
    /// „New Recording 3“), damit der sprechende Name greift; Standardnamen in einem anderen Datumsformat werden ins
    /// eingestellte umgeschrieben. Eigene Titel (oder Ortsnamen) bleiben.
    static func standardName(_ f: URL, date: Date) -> String? {
        if RecordingTitle.defaultStamp(f) != nil { return RecordingName.reformatted(f) }
        let stem = f.deletingPathExtension().lastPathComponent
        guard stem.wholeMatch(of: #/(?:Neue Aufnahme|New Recording)(?: \d+)?/#) != nil else { return nil }
        return RecordingName.defaultName(date)
    }

    @discardableResult
    static func tick(force: Bool = false) -> [URL] {
        guard enabled || force else { return [] }
        let files = (try? FileManager.default.contentsOfDirectory(at: downloads, includingPropertiesForKeys: nil,
                                                                   options: [.skipsHiddenFiles])) ?? []
        var moved: [URL] = [], now: [String: [Int]] = [:]
        for f in files where audioExt.contains(f.pathExtension.lowercased()) {
            var st = stat()
            guard lstat(f.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG,
                  Double(st.st_birthtimespec.tv_sec) >= since, isAirDrop(f) else { continue }
            let sig = [Int(st.st_size), Int(st.st_mtimespec.tv_sec)]
            now[f.path] = sig
            guard seen[f.path] == sig else { continue }   // erst im nächsten Takt, wenn unverändert
            let date = Date(timeIntervalSince1970: Double(min(st.st_birthtimespec.tv_sec, st.st_mtimespec.tv_sec)))
            if let dest = ICloudInbox.move(f, named: standardName(f, date: date), label: "AirDrop-Eingang") {
                moved.append(dest); now.removeValue(forKey: f.path)
            }
        }
        seen = now
        return moved
    }

    /// Selbsttest `--airdrop-test [SEKUNDEN]`: Downloads abholen wie bei eingeschalteter Einstellung (nur Dateien seit
    /// dem letzten Einschalten bzw. seit `airdropInboxSince`); Ergebnis in app.log.
    static func selfTest(seconds: Double) {
        let end = Date().addingTimeInterval(seconds)
        var all: [URL] = []
        do {
            let files = try FileManager.default.contentsOfDirectory(at: downloads, includingPropertiesForKeys: nil)
            let audio = files.filter { audioExt.contains($0.pathExtension.lowercased()) }
            appLog("AirDrop-Test: Downloads lesbar, \(audio.count) Audiodateien, davon AirDrop: "
                   + audio.filter(isAirDrop).map(\.lastPathComponent).joined(separator: ", "))
        } catch { appLog("AirDrop-Test: Downloads nicht lesbar: \(error.localizedDescription)") }
        while Date() < end {
            all += ICloudInbox.queue.sync { tick(force: true) }
            if !all.isEmpty && seen.isEmpty { break }
            Thread.sleep(forTimeInterval: 5)
        }
        appLog("AirDrop-Test: \(all.count) übernommen" + all.map { "\n  \($0.path)" }.joined())
    }
}
