import AppKit
import CoreAudio
import UserNotifications

/// Erkennt Calls daran, dass eine Call-App das Mikrofon nutzt (Core-Audio-Prozessliste, macOS 14+: „läuft Eingabe“).
/// Nach `askAfter` s fragt eine Mitteilung „Aufnehmen?“ – aufgenommen wird nur auf Klick. Eine so gestartete Aufnahme
/// endet von selbst, wenn die Call-App das Mikrofon `endAfter` s lang nicht mehr nutzt. Systembausteine only.
/// Call-Aufnahmen (Mitteilung oder „Call aufnehmen“ im Panel) nehmen das Mikrofon, das die Call-App benutzt, und ziehen
/// bei einem Wechsel im Call nach (Test 2026-10-14: Meet nahm das USB-Studiomikrofon, der Transcriber den
/// Systemstandard = MacBook-Mikrofon). Den Ton der anderen nimmt der Process-Tap unabhängig vom Ausgabegerät.
@MainActor
final class CallDetector: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    /// Gerade erkannte Call-App (Anzeigename), nil = kein Call.
    @Published var current: String?
    /// Eingabegerät der Call-App (Core-Audio-UID und Name), soweit Core Audio es verrät.
    @Published var micUID: String?
    @Published var micName: String?

    /// Bundle-ID-Präfixe → Anzeigename. Browser zählen mit (Meet, Teams im Browser); gefragt wird ohnehin vorher.
    nonisolated static let apps: [(prefix: String, name: String)] = [
        ("com.microsoft.teams", "Teams"), ("us.zoom", "Zoom"), ("com.apple.FaceTime", "FaceTime"),
        ("com.tinyspeck.slackmacgap", "Slack"), ("com.cisco.webex", "Webex"), ("Cisco-Systems.Spark", "Webex"),
        ("com.hnc.Discord", "Discord"), ("app.zen-browser.zen", "Zen"), ("org.mozilla.firefox", "Firefox"),
        ("com.google.Chrome", "Chrome"), ("com.apple.Safari", "Safari"), ("com.apple.WebKit", "Safari"),
        ("com.microsoft.edgemac", "Edge"), ("com.brave.Browser", "Brave"), ("company.thebrowser.Browser", "Arc"),
    ]
    static let askAfter: TimeInterval = 5
    static let endAfter: TimeInterval = 15

    var enabled: Bool { UserDefaults.standard.object(forKey: "callDetect") as? Bool ?? true }
    var isRecording: () -> Bool = { false }
    var startRecording: () -> Void = {}
    var stopRecording: () -> Void = {}
    var currentMic: () -> String? = { nil }          // UID, mit der gerade aufgenommen wird
    var switchMic: (String) -> Void = { _ in }
    var leaveVoiceProcessing: () -> Void = {}

    private var timer: Timer?
    private var since: Date?           // seit wann die Call-App das Mikrofon nutzt
    private var lastSeen: Date?
    private var asked = false          // in diesem Call schon gefragt
    private var startedByCall = false
    private var pendingMic: String?    // neues Call-Mikrofon, einmal gesehen
    private var switches: [Date] = []  // Mikrofonwechsel der letzten Minute
    private var gaveUp = false

    override init() {
        super.init()
        let c = UNUserNotificationCenter.current()
        c.delegate = self
        c.setNotificationCategories([UNNotificationCategory(
            identifier: "CALL", actions: [UNNotificationAction(identifier: "RECORD", title: String(localized: "Aufnehmen"), options: [])],
            intentIdentifiers: [], options: [])])
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in Task { @MainActor in self?.poll() } }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func poll() {
        guard enabled else { current = nil; return }
        let now = Date()
        if let call = Self.activeCall() {
            let app = call.app
            current = app; lastSeen = now
            if isRecording() { leaveVoiceProcessing() }    // kein Mikrofon-Konflikt mit der Call-App
            micName = call.micName
            if call.micUID != micUID { micUID = call.micUID }
            // Im Call umgestellt: erst nachziehen, wenn das neue Gerät zweimal hintereinander gemeldet wird; mehr als
            // drei Wechsel pro Minute → nicht mehr folgen (Schutz gegen Pendeln, jeder Wechsel kostet 1–3 s).
            if startedByCall, isRecording(), let uid = call.micUID, uid != currentMic() {
                if pendingMic == uid {
                    switches = switches.filter { now.timeIntervalSince($0) < 60 }
                    if switches.count < 3 {
                        switches.append(now)
                        appLog("Call-Mikrofon gewechselt: \(call.micName ?? uid)")
                        switchMic(uid)
                    } else if !gaveUp {
                        gaveUp = true
                        appLog("Call-Mikrofon pendelt – Aufnahme bleibt beim bisherigen Mikrofon")
                    }
                    pendingMic = nil
                } else {
                    pendingMic = uid
                }
            } else {
                pendingMic = nil
            }
            if since == nil { since = now }
            if !asked, !isRecording(), now.timeIntervalSince(since!) >= Self.askAfter {
                asked = true
                notify(String(localized: "Call in \(app) erkannt"), String(localized: "Aufnehmen? Mikrofon und Call-Ton werden getrennt aufgenommen."), category: "CALL")
                appLog("Call erkannt: \(app) – Geräte: \(Self.callDeviceReport())")
            }
        } else if let l = lastSeen, now.timeIntervalSince(l) >= Self.endAfter {
            if startedByCall && isRecording() {
                stopRecording()
                notify(String(localized: "Call beendet"), String(localized: "Aufnahme gestoppt, Transkription läuft."), category: nil)
                appLog("Call beendet: Aufnahme gestoppt")
            }
            current = nil; since = nil; lastSeen = nil; asked = false; startedByCall = false; micUID = nil; micName = nil
            pendingMic = nil; switches = []; gaveUp = false
        }
    }

    private func notify(_ title: String, _ body: String, category: String?) {
        let c = UNMutableNotificationContent()
        c.title = title; c.body = body
        if let category { c.categoryIdentifier = category }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "call-\(UUID())", content: c, trigger: nil))
    }

    // Klick auf „Aufnehmen“ oder auf die Mitteilung selbst.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler done: @escaping () -> Void) {
        let category = response.notification.request.content.categoryIdentifier
        if category == "UPDATE" { Task { @MainActor in UpdateCheck.openInstructions(); done() }; return }
        let isCall = category == "CALL"
        let start = isCall && ["RECORD", UNNotificationDefaultActionIdentifier].contains(response.actionIdentifier)
        Task { @MainActor in
            if start, self.recordCall() { appLog("Aufnahme aus Call-Mitteilung gestartet") }
            done()
        }
    }

    /// Call aufnehmen (Mitteilung oder Panel): Mikrofon wie im Call, endet mit dem Call.
    @discardableResult
    func recordCall() -> Bool {
        guard !isRecording() else { return false }
        startedByCall = true
        startRecording()
        return true
    }

    // Mitteilungen auch zeigen, während die App „vorn“ ist (Menüleisten-App).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .sound])
    }

    // MARK: Core Audio

    /// Erste Call-App, die gerade das Mikrofon nutzt: Anzeigename und ihr Eingabegerät (kAudioProcessPropertyDevices).
    nonisolated static func activeCall() -> (app: String, micUID: String?, micName: String?)? {
        for id in processObjects() where uint(id, kAudioProcessPropertyIsRunningInput) == 1 {
            guard let bid = bundleID(id), bid != Bundle.main.bundleIdentifier,
                  let app = apps.first(where: { bid.hasPrefix($0.prefix) }) else { continue }
            // Mit Sprachverarbeitung (WebRTC/Meet) stehen im Eingabe-Scope auch Lautsprecher/Kopfhörer (Echo-Referenz);
            // die stehen aber immer auch im Ausgabe-Scope. Eingangskanäle allein reichen nicht: nimmt der Transcriber
            // selbst mit Sprachverarbeitung auf, bekommt der MacBook-Lautsprecher zeitweise einen Eingang → Wechsel im
            // 2-s-Takt (Test 2026-10-14). Also: im Eingabe-, nicht im Ausgabe-Scope, und mit Eingangskanälen.
            let outs = Set(devices(id, kAudioObjectPropertyScopeOutput))
            let dev = inputDevices(id).first { !outs.contains($0) && hasInput($0) }
            return (app.name, dev.flatMap { Recorder.deviceString($0, kAudioDevicePropertyDeviceUID) },
                    dev.flatMap { Recorder.deviceString($0, kAudioObjectPropertyName) })
        }
        return nil
    }

    /// Eingabegeräte dieses Prozesses laut Core Audio (Kontrolle nach einem Mikrofonwechsel).
    nonisolated static func ownInputDeviceNames() -> [String] {
        let me = processObjects().first { uint($0, kAudioProcessPropertyPID) == UInt32(getpid()) }
        return me.map { inputDevices($0).compactMap { Recorder.deviceString($0, kAudioObjectPropertyName) } } ?? []
    }

    nonisolated static func hasInput(_ dev: AudioObjectID) -> Bool {
        var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeInput,
                                           mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(dev, &a, 0, nil, &size) == noErr && size > 0
    }

    /// Für das Protokoll: alle Geräte der Call-App im Eingabe-Scope mit Kennzeichen, ob sie Eingangskanäle haben.
    nonisolated static func callDeviceReport() -> String {
        processObjects().filter { uint($0, kAudioProcessPropertyIsRunningInput) == 1 }.compactMap { id -> String? in
            guard let bid = bundleID(id), bid != Bundle.main.bundleIdentifier, apps.contains(where: { bid.hasPrefix($0.prefix) }) else { return nil }
            let devs = inputDevices(id).map { "\(Recorder.deviceString($0, kAudioObjectPropertyName) ?? "?")\(hasInput($0) ? "" : " (ohne Eingang)")" }
            return "\(bid): \(devs.joined(separator: ", "))"
        }.joined(separator: " | ")
    }

    nonisolated static func inputDevices(_ id: AudioObjectID) -> [AudioObjectID] { devices(id, kAudioObjectPropertyScopeInput) }

    nonisolated static func devices(_ id: AudioObjectID, _ scope: AudioObjectPropertyScope) -> [AudioObjectID] {
        var a = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyDevices, mScope: scope,
                                           mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    nonisolated static func processObjects() -> [AudioObjectID] {
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                           mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    nonisolated static func uint(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector) -> UInt32 {
        var a = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var v: UInt32 = 0; var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &a, 0, nil, &size, &v) == noErr ? v : 0
    }

    nonisolated static func bundleID(_ id: AudioObjectID) -> String? {
        var a = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID, mScope: kAudioObjectPropertyScopeGlobal,
                                           mElement: kAudioObjectPropertyElementMain)
        var cf: Unmanaged<CFString>?; var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &cf) == noErr, let s = cf?.takeRetainedValue() else { return nil }
        return s as String
    }
}
