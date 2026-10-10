import AVFoundation
import ScreenCaptureKit
import SwiftUI
import CoreAudio

/// Selbsttest/Klangvergleich: `open -n ~/Applications/Transcriber.app --args --vp-test`
/// Nimmt je 6 s ohne und mit Apple Voice Processing auf (Mixer nicht anfassen – sonst Fehler -10875 beim Ausgang),
/// schreibt Pegel je Kanal in app.log und Kanal 1 als WAV nach ~/.local/share/transcriber/vp-test-{roh,vp}.wav.
enum VPTest {
    static func capture(vp: Bool, seconds: Double) {
        let e = AVAudioEngine()
        let name = vp ? "vp" : "roh"
        do {
            let inNode = e.inputNode
            if vp { try inNode.setVoiceProcessingEnabled(true) }
            let fmt = inNode.outputFormat(forBus: 0)
            let n = Int(fmt.channelCount)
            var peaks = [Float](repeating: 0, count: n)
            let url = Core.data.appendingPathComponent("vp-test-\(name).wav")
            let mono = AVAudioFormat(standardFormatWithSampleRate: fmt.sampleRate, channels: 1)!
            let file = try AVAudioFile(forWriting: url, settings: mono.settings)
            inNode.installTap(onBus: 0, bufferSize: 4096, format: fmt) { buf, _ in
                guard let ch = buf.floatChannelData else { return }
                let len = Int(buf.frameLength)
                for c in 0..<n { for i in 0..<len { peaks[c] = max(peaks[c], abs(ch[c][i])) } }
                let out = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: buf.frameLength)!
                out.frameLength = buf.frameLength
                memcpy(out.floatChannelData![0], ch[0], len * 4)
                try? file.write(from: out)
            }
            e.prepare(); try e.start()
            Thread.sleep(forTimeInterval: seconds)
            e.stop(); inNode.removeTap(onBus: 0)
            appLog("VP-Test \(name): \(fmt), Spitze je Kanal \(peaks.map { String(format: "%.3f", $0) })")
        } catch {
            appLog("VP-Test \(name): FEHLER \(error)")
        }
    }

    /// Startzeit fürs Diktat: `open -n ~/Applications/Transcriber.app --args --latency-test`
    /// Je Modus 3×: Dauer von start() und Zeit bis zum ersten Audiopuffer (→ app.log).
    static func latency() {
        for vp in [false, false, false] {
            let e = AVAudioEngine()
            let t0 = Date()
            var first: TimeInterval?
            let lock = NSLock()
            do {
                if vp { try e.inputNode.setVoiceProcessingEnabled(true) }
                let fmt = e.inputNode.outputFormat(forBus: 0)
                e.inputNode.installTap(onBus: 0, bufferSize: 1024, format: fmt) { _, _ in
                    lock.lock(); if first == nil { first = Date().timeIntervalSince(t0) }; lock.unlock()
                }
                e.prepare(); try e.start()
                let started = Date().timeIntervalSince(t0)
                Thread.sleep(forTimeInterval: 1.5)
                e.stop(); e.inputNode.removeTap(onBus: 0)
                lock.lock(); let f = first; lock.unlock()
                appLog(String(format: "Latenz %@: start() %.0f ms, erster Puffer %@", vp ? "VP " : "roh",
                              started * 1000, f.map { String(format: "%.0f ms", $0 * 1000) } ?? "keiner"))
            } catch { appLog("Latenz \(vp ? "VP" : "roh"): FEHLER \(error)") }
            Thread.sleep(forTimeInterval: 0.5)
        }
        // Vorbereitet (Muster VoiceInk): Engine + Tap einmal aufbauen, beim „Tastendruck“ nur start().
        // Dazu: läuft das Gerät im gestoppten Zustand irgendwo (= oranger Punkt)?
        let e = AVAudioEngine()
        let lock = NSLock()
        var t0 = Date(), first: TimeInterval?
        let fmt = e.inputNode.outputFormat(forBus: 0)
        e.inputNode.installTap(onBus: 0, bufferSize: 1024, format: fmt) { _, _ in
            lock.lock(); if first == nil { first = Date().timeIntervalSince(t0) }; lock.unlock()
        }
        e.prepare()
        for i in 0..<5 {
            Thread.sleep(forTimeInterval: 2)
            let idle = Recorder.defaultInputDevice().map(isRunningSomewhere) ?? -1
            lock.lock(); first = nil; t0 = Date(); lock.unlock()
            do { try e.start() } catch { appLog("Latenz vorbereitet: FEHLER \(error)"); break }
            let started = Date().timeIntervalSince(t0)
            Thread.sleep(forTimeInterval: 1)
            let running = Recorder.defaultInputDevice().map(isRunningSomewhere) ?? -1
            e.pause()
            lock.lock(); let f = first; lock.unlock()
            appLog(String(format: "Latenz vorbereitet #%d: start() %.0f ms, erster Puffer %@, Gerät läuft gestoppt=%d gestartet=%d", i,
                          started * 1000, f.map { String(format: "%.0f ms", $0 * 1000) } ?? "keiner", idle, running))
        }
        e.stop()
        Thread.sleep(forTimeInterval: 1)
        appLog("Latenz nach stop(): Gerät läuft=\(Recorder.defaultInputDevice().map(isRunningSomewhere) ?? -1)")
        appLog("Latenz-Test: fertig")
    }

    /// KI-Aufräumen mit Bildschirmtext ohne Tastendruck: `open -n ~/Applications/Transcriber.app --args --cleanup-test`
    /// Liest das vorderste Fenster (nach 1 s, damit die eigene App nicht vorn ist), räumt Beispieldiktate auf (→ app.log).
    static func cleanup() async {
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        let screen = await ScreenContext.capture()
        appLog("Aufräum-Test: Bildschirmtext \(screen?.count ?? 0) Zeichen")
        for raw in ["kannst du äh in der datei dictation cleanup punkt swift nachschauen ob der test durchläuft",
                    "Wie gut wäre denn Mac Whisper dafür geeignet? Weißt du das?"] {
            let (out, note) = await DictationCleanup.clean(raw, screen: screen)
            appLog("Aufräum-Test: [\(note)] \(raw) → \(out)")
        }
        appLog("Aufräum-Test: fertig")
    }

    /// Titelvorschläge ohne Umbenennen: `open -n ~/Applications/Transcriber.app --args --title-test A.transcript.json …`
    static func titles(_ files: [URL]) async {
        for f in files {
            let t0 = Date()
            let title = await RecordingTitle.excerpt(f).asyncMap { await RecordingTitle.generate(from: $0) } ?? nil
            appLog(String(format: "Titel-Test %.1f s: %@ → %@", Date().timeIntervalSince(t0), f.lastPathComponent, title ?? "–"))
        }
        appLog("Titel-Test: fertig")
    }

    /// Process-Tap ohne Ton aus den Lautsprechern: `open -n ~/Applications/Transcriber.app --args --tap-test`
    /// Greift alles außer Transcriber stumm ab (muted), spielt einen Systemton per afplay, misst Pegel und Dauer (→ app.log).
    static func tap() {
        guard #available(macOS 14.2, *) else { appLog("Tap-Test: braucht macOS 14.2"); return }
        let tap = ProcessTap()
        let lock = NSLock()
        var frames = 0, peak: Float = 0, first: UInt64 = 0
        do {
            try tap.start(muted: true) { buf, host in
                guard let ch = buf.floatChannelData else { return }
                var p: Float = 0
                for i in 0..<Int(buf.frameLength) { p = max(p, abs(ch[0][i])) }
                lock.lock(); frames += Int(buf.frameLength); peak = max(peak, p); if first == 0 { first = host }; lock.unlock()
            }
            appLog("Tap-Test: läuft, Format \(tap.format?.description ?? "?")")
            Thread.sleep(forTimeInterval: 0.5)
            let player = Process()
            player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
            player.arguments = ["/System/Library/Sounds/Glass.aiff"]
            try player.run(); player.waitUntilExit()
            Thread.sleep(forTimeInterval: 0.5)
            tap.stop()
            lock.lock(); let f = frames, pk = peak; lock.unlock()
            let sr = tap.format?.sampleRate ?? 48000
            appLog(String(format: "Tap-Test: %.1f s Audio, Spitze %.3f → %@", Double(f) / sr, pk, pk > 0.01 ? "Ton angekommen" : "STILLE"))
        } catch {
            appLog("Tap-Test: FEHLER \(error.localizedDescription)")
        }
        appLog("Tap-Test: fertig")
    }

    /// Kalender lesen: `open -n ~/Applications/Transcriber.app --args --calendar-test` (→ app.log, ohne E-Mail-Adressen)
    static func calendar() async {
        guard await CalendarContext.access() else { appLog("Kalender-Test: kein Zugriff"); appLog("Kalender-Test: fertig"); return }
        let cal = Calendar.current, now = Date()
        let pred = CalendarContext.store.predicateForEvents(withStart: cal.startOfDay(for: now),
                                                           end: cal.startOfDay(for: now).addingTimeInterval(86400), calendars: nil)
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        for e in CalendarContext.store.events(matching: pred) where !e.isAllDay {
            let me = e.attendees?.contains(where: \.isCurrentUser) ?? false
            appLog("Kalender-Test: \(f.string(from: e.startDate))–\(f.string(from: e.endDate)) \(e.title ?? "?") · \(e.attendees?.count ?? 0) Teilnehmer"
                   + (me ? " (ich dabei)" : "") + " · Kalender \(e.calendar?.title ?? "?") · Rang \(CalendarContext.rank(e))")
        }
        appLog("Kalender-Test: \(CalendarContext.calendars().count) Kalender, davon abgewählt \(CalendarContext.excluded.count)")
        appLog("Kalender-Test: jetzt → \(CalendarContext.current()?.title ?? "kein Termin")")
        appLog("Kalender-Test: fertig")
    }

    /// Spurversatz: `open -n ~/Applications/Transcriber.app --args --gap-test ORDNER [--vp] [--gap SEKUNDEN]` – Aufnahme
    /// mit Systemton, die ersten SEKUNDEN (2,5) Systemton verworfen, danach spielt afplay leise einen Ton, 4 s später Stopp. Danach muss der Ton in der Systemton-Spur bei ~3 s liegen, nicht
    /// bei 0 s (Tap liefert erst, wenn etwas abspielt; Lücken füllt Recorder.append mit Stille).
    @MainActor
    static func gap(_ folder: URL, voiceProcessing: Bool = false, gap: Double = 2.5) async {
        let r = Recorder()
        r.testDropSystemUntil = Date().addingTimeInterval(gap)      // wie im frischen Konto: Tap liefert erst später
        do { try await r.start(deviceID: nil, systemAudio: true, voiceProcessing: voiceProcessing, folder: folder) }
        catch { appLog("Gap-Test: Start fehlgeschlagen: \(error.localizedDescription)"); return }
        try? await Task.sleep(nanoseconds: UInt64((gap + 0.5) * 1e9))
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        p.arguments = ["-v", "0.15", "/System/Library/Sounds/Submarine.aiff"]
        try? p.run()
        try? await Task.sleep(nanoseconds: 4_000_000_000)
        let url = await r.stop()
        appLog("Gap-Test: fertig → \(url?.path ?? "keine Datei")")
    }

    /// Oberfläche ansehen ohne Mausklick: `open -n ~/Applications/Transcriber.app --args --ui-test`
    /// Zeigt Panel und Einstellungs-Reiter kurz als Fenster, fotografiert sie (ScreenCaptureKit) → DATA/ui-*.png.
    @MainActor
    static func ui(recorder: Recorder, jobs: JobManager, dictation: Dictation, calls: CallDetector, updates: UpdateCheck) async {
        let views: [(String, AnyView)] = [
            ("panel", AnyView(PanelView().environmentObject(recorder).environmentObject(jobs).environmentObject(dictation).environmentObject(calls)
                .environmentObject(updates))),
            ("eintrag", AnyView(Group {
                if let j = jobs.jobs.first(where: { $0.state == .done && $0.speakers.count > 1 }) {
                    JobRow(job: j, editing: [j.speakers[0].letter]).environmentObject(jobs).frame(width: 412).padding(14)
                }
            })),
            ("allgemein", AnyView(GeneralSettings().environmentObject(updates).frame(width: 520, height: 440))),
            ("aufnahme", AnyView(RecordingSettings().frame(width: 520, height: 440))),
            ("diktat", AnyView(DictationSettings().environmentObject(dictation).frame(width: 520, height: 440))),
            ("kalender", AnyView(CalendarSettings().frame(width: 520, height: 440))),
        ]
        await jobs.loadNames()
        try? await Task.sleep(nanoseconds: 1_500_000_000)       // Aufträge einlesen lassen
        for (name, view) in views {
            let w = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 540, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
            w.contentView = NSHostingView(rootView: view)
            w.setContentSize(w.contentView!.fittingSize)
            w.level = .floating
            w.orderFrontRegardless()
            try? await Task.sleep(nanoseconds: 800_000_000)
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
                if let sw = content.windows.first(where: { $0.windowID == CGWindowID(w.windowNumber) }) {
                    let cfg = SCStreamConfiguration()
                    cfg.width = Int(sw.frame.width * 2); cfg.height = Int(sw.frame.height * 2)
                    let img = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: sw), configuration: cfg)
                    let url = Core.data.appendingPathComponent("ui-\(name).png")
                    try NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: url)
                    appLog("UI-Test: \(url.lastPathComponent)")
                }
            } catch { appLog("UI-Test: \(name) FEHLER \(error.localizedDescription)") }
            w.orderOut(nil)
        }
        appLog("UI-Test: fertig")
    }

    static func isRunningSomewhere(_ dev: AudioDeviceID) -> Int {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var v: UInt32 = 0; var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &v) == noErr ? Int(v) : -1
    }

    static func run() {
        capture(vp: false, seconds: 6)
        capture(vp: true, seconds: 6)
        appLog("VP-Test: fertig")
    }
}

extension Optional {
    func asyncMap<T>(_ f: (Wrapped) async -> T) async -> T? { if let v = self { return await f(v) }; return nil }
}
