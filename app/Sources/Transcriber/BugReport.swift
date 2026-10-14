import AppKit
import AVFoundation
import CoreAudio
import EventKit
import SwiftUI
import UserNotifications

/// Fehler melden: Beschreibung + ZIP-Datei (`transcriber report`, ohne Aufnahmen/Transkripte/Stimmdatenbank) an eine
/// fertige Mail an info@teconomix.net. Kein Server, kein Upload – der Nutzer sieht die Mail und schickt selbst ab.
/// Ohne eingerichtetes Mailprogramm: ZIP im Finder zeigen, Adresse in die Zwischenablage.
enum BugReport {
    static let recipient = "info@teconomix.net"

    /// macOS-Seite: Version, Mac, Freigaben, Audiogeräte, Einstellungen der App (keine Inhalte).
    @MainActor
    static func appInfo() async -> [String: Any] {
        let b = Bundle.main.infoDictionary ?? [:]
        let n = await UNUserNotificationCenter.current().notificationSettings()
        let mic: String = switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: "erlaubt"; case .denied: "verweigert"; case .restricted: "eingeschränkt"; default: "nicht gefragt"
        }
        let cal: String = switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: "Vollzugriff"; case .writeOnly: "nur schreiben"; case .denied: "verweigert"; case .restricted: "eingeschränkt"
        default: "nicht gefragt"
        }
        let style: String = switch n.alertStyle { case .alert: "Hinweise"; case .banner: "Banner"; default: "keine" }
        let keys = ["micID", "language", "languages", "voiceProcessing", "systemAudio", "autoTranscribe", "autoTitle", "callDetect",
                    "useCalendar", "dictation", "dictationKey", "dictationCleanKey", "dictationVP", "dictationSound",
                    "dictationIndicator", "dictationScreenContext", "nextSpeakers", "updateCheck", "updateLatest"]
        var settings: [String: Any] = [:]
        for k in keys { if let v = UserDefaults.standard.object(forKey: k) { settings[k] = v } }
        settings["calendarsExcluded"] = (UserDefaults.standard.stringArray(forKey: "calendarsExcluded") ?? []).count
        let call = CallDetector.activeCall()
        return [
            "app": ["version": b["CFBundleShortVersionString"] ?? "?", "build": b["CFBundleVersion"] ?? "?",
                    "ui_language": Core.uiLanguage, "system_languages": Locale.preferredLanguages.prefix(3).joined(separator: ", ")],
            "mac": ["macos": ProcessInfo.processInfo.operatingSystemVersionString, "model": sysctl("hw.model"),
                    "cpu": sysctl("machdep.cpu.brand_string"), "memory_gb": ProcessInfo.processInfo.physicalMemory / 1_000_000_000],
            "permissions": ["microphone": mic, "accessibility": AXIsProcessTrusted() ? "erlaubt" : "fehlt",
                            "screen_recording": CGPreflightScreenCaptureAccess() ? "erlaubt" : "fehlt",
                            "system_audio": "nicht abfragbar (kein öffentlicher Weg)", "calendar": cal,
                            "notifications": n.authorizationStatus == .authorized ? "erlaubt" : "fehlt", "notification_style": style],
            "audio": audioDevices(),
            "call": call.map { ["app": $0.app, "mic": $0.micName ?? "?", "devices": CallDetector.callDeviceReport()] } ?? [:],
            "settings": settings,
        ]
    }

    static func sysctl(_ name: String) -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "?" }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return "?" }
        return String(cString: buf)
    }

    /// Alle Core-Audio-Geräte mit Ein-/Ausgang und Standard-Markierung.
    static func audioDevices() -> [[String: Any]] {
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
                                           mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &ids) == noErr else { return [] }
        let defIn = Recorder.defaultInputDevice()
        var o = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal,
                                           mElement: kAudioObjectPropertyElementMain)
        var defOut = AudioObjectID(0); var s4 = UInt32(MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &o, 0, nil, &s4, &defOut)
        return ids.map { id in
            ["name": Recorder.deviceString(id, kAudioObjectPropertyName) ?? "?", "input": CallDetector.hasInput(id),
             "default_input": id == defIn, "default_output": id == defOut]
        }
    }

    /// ZIP-Datei im Download-Ordner erstellen; liefert ihren Pfad oder eine Fehlermeldung.
    @MainActor
    static func create(description: String, redact: Bool) async -> (url: URL?, error: String?) {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("transcriber-report-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let desc = tmp.appendingPathComponent("beschreibung.txt"), info = tmp.appendingPathComponent("app.json")
        try? description.write(to: desc, atomically: true, encoding: .utf8)
        if let d = try? JSONSerialization.data(withJSONObject: await appInfo(), options: [.prettyPrinted, .sortedKeys]) { try? d.write(to: info) }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH-mm"
        let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? FileManager.default.homeDirectoryForCurrentUser
        let zip = dir.appendingPathComponent(String(localized: "Transcriber-Fehlerbericht") + " \(f.string(from: Date())).zip")
        let (ok, out) = await Core.run(["report", zip.path, "--description", desc.path, "--app-info", info.path] + (redact ? [] : ["--keep-names"]))
        return ok && FileManager.default.fileExists(atPath: zip.path) ? (zip, nil) : (nil, out.split(separator: "\n").suffix(3).joined(separator: "\n"))
    }

    /// Mail mit Anhang öffnen. false = kein Mailprogramm, das Anhänge annimmt.
    @MainActor
    static func compose(zip: URL, description: String) -> Bool {
        guard let s = NSSharingService(named: .composeEmail) else { return false }
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        s.recipients = [recipient]
        s.subject = String(localized: "Transcriber-Fehlerbericht") + " (\(version))"
        let body = description.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n"
            + String(localized: "Angehängt: Protokolle und Systeminfos (ohne Aufnahmen, Transkripte und Stimmdatenbank).")
        let items: [Any] = [body, zip]
        guard s.canPerform(withItems: items) else { return false }
        s.perform(withItems: items)
        return true
    }
}

/// Vorbelegung, z. B. aus einem fehlgeschlagenen Auftrag („Fehler melden …“ im Eintrag).
@MainActor
final class ReportDraft: ObservableObject {
    static let shared = ReportDraft()
    @Published var text = ""
}

struct ReportView: View {
    @ObservedObject private var draft = ReportDraft.shared
    @State private var redact = true
    @State private var busy = false
    @State private var result: String?
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Was ist passiert?").font(.headline)
            Text("Was hast du gemacht, was hast du erwartet, was ist stattdessen passiert?")
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $draft.text).font(.callout).frame(minHeight: 120)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.3)))
            Toggle("Dateinamen und Termintitel unkenntlich machen", isOn: $redact)
            Text("Angehängt werden Protokolle, Version, Mac-Modell, macOS, Freigaben, Audiogeräte und Einstellungen – keine Aufnahmen, keine Transkripte, keine Stimmdatenbank. Die Mail geht an \(BugReport.recipient); du siehst sie vor dem Absenden.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let r = result { Text(r).font(.caption).textSelection(.enabled) }
            HStack {
                if busy { ProgressView().controlSize(.small); Text("Bericht wird erstellt …").font(.caption) }
                Spacer()
                Button("Abbrechen", role: .cancel) { dismissWindow(id: "report") }.keyboardShortcut(.cancelAction)
                Button("Bericht erstellen …") { Task { await create() } }.keyboardShortcut(.defaultAction).disabled(busy)
            }
        }
        .padding(16)
        .frame(width: 480)
    }

    private func create() async {
        busy = true; result = nil
        defer { busy = false }
        let r = await BugReport.create(description: draft.text, redact: redact)
        if let zip = r.url {
            if BugReport.compose(zip: zip, description: draft.text) {
                draft.text = ""
                dismissWindow(id: "report")
            } else {                 // kein Mailprogramm mit Anhängen (z. B. nur Gmail im Browser)
                NSWorkspace.shared.activateFileViewerSelecting([zip])
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(BugReport.recipient, forType: .string)
                result = String(localized: "Kein Mailprogramm gefunden. Die Datei liegt im Download-Ordner (im Finder markiert); die Adresse \(BugReport.recipient) ist in der Zwischenablage – bitte die Datei an eine Mail hängen.")
            }
        } else {
            result = String(localized: "Bericht konnte nicht erstellt werden: \(r.error ?? "?")")
        }
    }
}
