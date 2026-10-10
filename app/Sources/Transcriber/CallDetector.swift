import AppKit
import CoreAudio
import UserNotifications

/// Erkennt Calls daran, dass eine Call-App das Mikrofon nutzt (Core-Audio-Prozessliste, macOS 14+: „läuft Eingabe“).
/// Nach `askAfter` s fragt eine Mitteilung „Aufnehmen?“ – aufgenommen wird nur auf Klick. Eine so gestartete Aufnahme
/// endet von selbst, wenn die Call-App das Mikrofon `endAfter` s lang nicht mehr nutzt. Systembausteine only.
@MainActor
final class CallDetector: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    /// Gerade erkannte Call-App (Anzeigename), nil = kein Call.
    @Published var current: String?

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

    private var timer: Timer?
    private var since: Date?           // seit wann die Call-App das Mikrofon nutzt
    private var lastSeen: Date?
    private var asked = false          // in diesem Call schon gefragt
    private var startedByCall = false

    override init() {
        super.init()
        let c = UNUserNotificationCenter.current()
        c.delegate = self
        c.setNotificationCategories([UNNotificationCategory(
            identifier: "CALL", actions: [UNNotificationAction(identifier: "RECORD", title: "Aufnehmen", options: [])],
            intentIdentifiers: [], options: [])])
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in Task { @MainActor in self?.poll() } }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func poll() {
        guard enabled else { current = nil; return }
        let now = Date()
        if let app = Self.callAppUsingMic() {
            current = app; lastSeen = now
            if since == nil { since = now }
            if !asked, !isRecording(), now.timeIntervalSince(since!) >= Self.askAfter {
                asked = true
                notify("Call in \(app) erkannt", "Aufnehmen? Mikrofon und Call-Ton werden getrennt aufgenommen.", category: "CALL")
                appLog("Call erkannt: \(app)")
            }
        } else if let l = lastSeen, now.timeIntervalSince(l) >= Self.endAfter {
            if startedByCall && isRecording() {
                stopRecording()
                notify("Call beendet", "Aufnahme gestoppt, Transkription läuft.", category: nil)
                appLog("Call beendet: Aufnahme gestoppt")
            }
            current = nil; since = nil; lastSeen = nil; asked = false; startedByCall = false
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
        let isCall = response.notification.request.content.categoryIdentifier == "CALL"
        let start = isCall && ["RECORD", UNNotificationDefaultActionIdentifier].contains(response.actionIdentifier)
        Task { @MainActor in
            if start, !self.isRecording() {
                self.startedByCall = true
                self.startRecording()
                appLog("Aufnahme aus Call-Mitteilung gestartet")
            }
            done()
        }
    }

    // Mitteilungen auch zeigen, während die App „vorn“ ist (Menüleisten-App).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .sound])
    }

    // MARK: Core Audio

    /// Anzeigename der ersten Call-App, die gerade das Mikrofon nutzt.
    nonisolated static func callAppUsingMic() -> String? {
        for id in processObjects() where uint(id, kAudioProcessPropertyIsRunningInput) == 1 {
            guard let bid = bundleID(id), bid != Bundle.main.bundleIdentifier else { continue }
            if let app = apps.first(where: { bid.hasPrefix($0.prefix) }) { return app.name }
        }
        return nil
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
