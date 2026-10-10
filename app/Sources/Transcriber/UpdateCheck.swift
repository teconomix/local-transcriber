import AppKit
import UserNotifications

/// Update-Hinweis: einmal täglich https://transcriber.teconomix.net/latest.txt lesen (nur die Versionsnummer; es geht
/// nichts über den Nutzer oder seine Aufnahmen hinaus, kein Cookie, eigener User-Agent). Nur nach Zustimmung: Das Panel
/// fragt beim ersten Öffnen, danach Schalter in Einstellungen › Allgemein. Aktualisiert wird mit dem Installer –
/// der Knopf öffnet die Installationsanleitung der Website.
@MainActor
final class UpdateCheck: ObservableObject {
    static let latestURL = URL(string: "https://transcriber.teconomix.net/latest.txt")!
    static let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    private static let interval: TimeInterval = 86400

    /// Neuere Version als die laufende, sonst nil.
    @Published var available: String?
    @Published var checking = false
    @Published var lastError: String?
    private var timer: Timer?
    private let d = UserDefaults.standard

    /// nil = noch nicht gefragt.
    var enabled: Bool? { d.object(forKey: "updateCheck") as? Bool }
    var lastChecked: Date? { d.object(forKey: "updateCheckedAt").map { _ in Date(timeIntervalSince1970: d.double(forKey: "updateCheckedAt")) } }

    init() {
        if enabled == true, let v = d.string(forKey: "updateLatest"), Self.isNewer(v, than: Self.current) { available = v }
        let t = Timer(timeInterval: 3600, repeats: true) { [weak self] _ in Task { @MainActor in await self?.checkIfDue() } }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        if !CommandLine.arguments.contains(where: { $0.hasSuffix("-test") }) { Task { await checkIfDue() } }
    }

    func set(_ on: Bool) {
        d.set(on, forKey: "updateCheck")
        objectWillChange.send()
        if on { Task { await check() } } else { available = nil; lastError = nil }
    }

    func checkIfDue() async {
        guard enabled == true, Date().timeIntervalSince1970 - d.double(forKey: "updateCheckedAt") >= Self.interval else { return }
        await check()
    }

    func check() async {
        guard enabled == true, !checking else { return }
        checking = true; defer { checking = false }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 15
        cfg.httpAdditionalHeaders = ["User-Agent": "Transcriber"]      // keine System- oder Geräteangaben
        do {
            let (data, resp) = try await URLSession(configuration: cfg).data(from: Self.latestURL)
            let v = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard (resp as? HTTPURLResponse)?.statusCode == 200, v.wholeMatch(of: #/\d+(\.\d+){1,3}/#) != nil else {
                throw URLError(.cannotParseResponse)
            }
            d.set(Date().timeIntervalSince1970, forKey: "updateCheckedAt")
            d.set(v, forKey: "updateLatest")
            lastError = nil
            available = Self.isNewer(v, than: Self.current) ? v : nil
            if let a = available, d.string(forKey: "updateNotified") != a { notify(a); d.set(a, forKey: "updateNotified") }
        } catch {
            lastError = error.localizedDescription
            appLog("Update-Prüfung fehlgeschlagen: \(error.localizedDescription)")
        }
    }

    /// Versionsnummern feldweise vergleichen („0.10.0“ > „0.9.1“).
    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    /// Installationsanleitung in der Sprache der Oberfläche (Installer erneut ausführen = aktualisieren).
    static func openInstructions() {
        NSWorkspace.shared.open(URL(string: "https://transcriber.teconomix.net/\(Core.uiLanguage)/#installation")!)
    }

    private func notify(_ v: String) {
        let c = UNMutableNotificationContent()
        c.title = String(localized: "Transcriber \(v) ist verfügbar")
        c.body = String(localized: "Zum Aktualisieren den Installationsbefehl erneut ausführen – Klick öffnet die Anleitung.")
        c.categoryIdentifier = "UPDATE"
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "update-\(v)", content: c, trigger: nil))
    }
}
