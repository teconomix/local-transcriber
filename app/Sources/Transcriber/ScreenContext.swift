import AppKit
import ScreenCaptureKit
import Vision

/// Text des aktiven Fensters als Kontext fürs KI-Aufräumen (nur ⌥-Modus): Namen, Dateinamen und Fachbegriffe richtig
/// schreiben. Bild des vordersten Fensters der aktiven App (ScreenCaptureKit, Freigabe „Bildschirmaufnahme“ – der
/// Systemton braucht sie seit dem Process-Tap nicht mehr, macOS fragt also beim ersten ⌥-Diktat) → Texterkennung (Vision, lokal). Läuft parallel zur Aufnahme. Bild und Text bleiben im
/// Arbeitsspeicher, nichts wird gespeichert oder protokolliert (nur die Zeichenzahl).
/// Über die Bedienungshilfen ginge es ohne Bild, liefert in Electron-Apps (Claude, Slack, VS Code) aber kaum Text.
///
/// Test 2026-10-10: „Mac Whisper“ → MacWhisper, „dictation cleanup punkt swift“ → DictationCleanup.swift; ganzer
/// Fenstertext wirkte besser als eine daraus gezogene Begriffsliste; eine eingeschleuste Anweisung im Bildschirmtext
/// wurde ignoriert.
enum ScreenContext {
    /// Das Apple-Modell hat 8192 Tokens Kontext; mehr Bildschirmtext verdrängt nur Anweisung und Diktat.
    static let maxChars = 6000
    /// Länger wartet das Aufräumen nach der Erkennung nicht auf den Bildschirmtext.
    static let maxWait: UInt64 = 1_500_000_000

    /// Die genaue Texterkennung lädt beim ersten Aufruf ~24 s (gemessen 2026-10-10), danach ~100 ms für ein Fenster.
    /// Deshalb einmal beim Einschalten im Hintergrund mit einem kleinen Bild durchlaufen lassen.
    static func prewarm() {
        Task.detached(priority: .background) {
            let t0 = Date()
            let img = NSImage(size: NSSize(width: 200, height: 40), flipped: false) { r in
                NSColor.white.setFill(); r.fill()
                ("Transcriber" as NSString).draw(at: NSPoint(x: 8, y: 10), withAttributes: [.font: NSFont.systemFont(ofSize: 18)])
                return true
            }
            guard let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
            _ = try? recognize(cg)
            appLog(String(format: "Diktat: Texterkennung vorgewärmt in %.1f s", Date().timeIntervalSince(t0)))
        }
    }

    /// Ergebnis von `capture()`, aber höchstens `maxWait` warten (sonst ohne Bildschirmtext weiter).
    static func value(of task: Task<String?, Never>?) async -> String? {
        guard let task else { return nil }
        // Kein TaskGroup: der wartet beim Verlassen auf alle Kinder, und das Warten auf task.value lässt sich nicht abbrechen.
        let once = Once()
        return await withCheckedContinuation { cont in
            Task { let v = await task.value; if once.claim() { cont.resume(returning: v) } }
            Task {
                try? await Task.sleep(nanoseconds: maxWait)
                if once.claim() { appLog("Diktat: Bildschirmtext nicht rechtzeitig fertig, ohne ihn weiter"); cont.resume(returning: nil) }
            }
        }
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
    }

    static func capture() async -> String? {
        let t0 = Date()
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid(),
              let windowID = frontWindowID(pid: app.processIdentifier) else { return nil }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            guard let w = content.windows.first(where: { $0.windowID == windowID }) else { return nil }
            let scale = NSScreen.screens.first { $0.frame.intersects(w.frame) }?.backingScaleFactor ?? 2
            let cfg = SCStreamConfiguration()
            cfg.width = Int(w.frame.width * scale); cfg.height = Int(w.frame.height * scale)
            cfg.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: w),
                                                                   configuration: cfg)
            let text = try recognize(image)
            appLog(String(format: "Diktat: Bildschirmtext %d Zeichen in %.0f ms", text.count, Date().timeIntervalSince(t0) * 1000))
            return text.isEmpty ? nil : trimmed(text)
        } catch {
            appLog("Diktat: Bildschirmtext nicht lesbar: \(error.localizedDescription)")
            return nil
        }
    }

    /// Vorderstes normales Fenster (Ebene 0) des Prozesses; die Fensterliste ist von vorn nach hinten sortiert.
    private static func frontWindowID(pid: pid_t) -> CGWindowID? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        return list.first { ($0[kCGWindowOwnerPID as String] as? pid_t) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }
            .flatMap { $0[kCGWindowNumber as String] as? CGWindowID }
    }

    private static func recognize(_ image: CGImage) throws -> String {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.recognitionLanguages = ["de-DE", "en-US"]
        req.usesLanguageCorrection = true
        try VNImageRequestHandler(cgImage: image).perform([req])
        return (req.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    /// Zu lang: Anfang (Kopfzeilen, Betreff, Empfänger) und Ende (jüngster Verlauf in Chat/Terminal) behalten.
    private static func trimmed(_ text: String) -> String {
        guard text.count > maxChars else { return text }
        return String(text.prefix(maxChars / 3)) + "\n…\n" + String(text.suffix(maxChars * 2 / 3))
    }
}
