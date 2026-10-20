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

    /// Kalender lesen: `open -n ~/Applications/Transcriber.app --args --calendar-test [--at "JJJJ-MM-TT HH:MM"]`
    /// (→ app.log, ohne E-Mail-Adressen); `--at` = welchen Termin hätte eine Aufnahme zu dieser Zeit bekommen.
    static func calendar() async {
        guard await CalendarContext.access() else { appLog("Kalender-Test: kein Zugriff"); appLog("Kalender-Test: fertig"); return }
        let a = CommandLine.arguments
        let atF = DateFormatter(); atF.dateFormat = "yyyy-MM-dd HH:mm"
        let cal = Calendar.current
        let now = a.firstIndex(of: "--at").flatMap { $0 + 1 < a.count ? atF.date(from: a[$0 + 1]) : nil } ?? Date()
        let pred = CalendarContext.store.predicateForEvents(withStart: cal.startOfDay(for: now),
                                                           end: cal.startOfDay(for: now).addingTimeInterval(86400), calendars: nil)
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        for e in CalendarContext.store.events(matching: pred) where !e.isAllDay {
            let me = e.attendees?.contains(where: \.isCurrentUser) ?? false
            appLog("Kalender-Test: \(f.string(from: e.startDate))–\(f.string(from: e.endDate)) \(e.title ?? "?") · \(e.attendees?.count ?? 0) Teilnehmer"
                   + (me ? " (ich dabei)" : "") + " · Kalender \(e.calendar?.title ?? "?") · Rang \(CalendarContext.rank(e))")
        }
        appLog("Kalender-Test: \(CalendarContext.calendars().count) Kalender, davon abgewählt \(CalendarContext.excluded.count)")
        appLog("Kalender-Test: \(atF.string(from: now)) → \(CalendarContext.current(at: now)?.title ?? "kein Termin")")
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

    /// Mikrofonwechsel mitten in der Aufnahme (wie wenn die Call-App umstellt):
    /// `open -n ~/Applications/Transcriber.app --args --mic-switch-test ORDNER` – je 4 s Standard → anderes Mikrofon →
    /// Standard, mit Sprachverarbeitung, ohne Systemton. Ergebnis im app.log, Datei im ORDNER.
    static func micSwitch(_ folder: URL) async {
        let def = Recorder.defaultInputDevice().flatMap { Recorder.deviceString($0, kAudioDevicePropertyDeviceUID) }
        guard let other = Recorder.microphones().first(where: { $0.uniqueID != def }) else {
            appLog("Mic-Switch-Test: kein zweites Mikrofon"); return
        }
        let r = Recorder()
        do { try await r.start(deviceID: nil, systemAudio: false, voiceProcessing: true, folder: folder) }
        catch { appLog("Mic-Switch-Test: Start fehlgeschlagen: \(error.localizedDescription)"); return }
        try? await Task.sleep(nanoseconds: 4_000_000_000)
        appLog("Mic-Switch-Test: Eingabe laut Core Audio: \(CallDetector.ownInputDeviceNames())")
        await MainActor.run { do { try r.switchMic(deviceID: other.uniqueID, voiceProcessing: true) } catch { appLog("Mic-Switch-Test: Wechsel 1: \(error)") } }
        try? await Task.sleep(nanoseconds: 4_000_000_000)
        appLog("Mic-Switch-Test: Eingabe laut Core Audio: \(CallDetector.ownInputDeviceNames())")
        if let def { await MainActor.run { do { try r.switchMic(deviceID: def, voiceProcessing: true) } catch { appLog("Mic-Switch-Test: Wechsel 2: \(error)") } } }
        try? await Task.sleep(nanoseconds: 4_000_000_000)
        appLog("Mic-Switch-Test: Eingabe laut Core Audio: \(CallDetector.ownInputDeviceNames())")
        let url = await r.stop()
        appLog("Mic-Switch-Test: fertig → \(url?.path ?? "keine Datei") (Wechsel zu \(other.localizedName) und zurück)")
    }

    /// Gegenstelle für den Call-Konflikt-Test: nimmt das Standardmikrofon auf wie eine Call-App (mit oder ohne Apple-
    /// Sprachverarbeitung) und schreibt je 0,5 s „Unixzeit Pegel-dB Samples“ nach `out`.
    static func micProbe(vp: Bool, out: URL, seconds: Double) {
        let e = AVAudioEngine()
        let lock = NSLock()
        var acc = 0.0, cnt = 0
        var lines: [String] = []
        do {
            let inNode = e.inputNode
            if vp { try inNode.setVoiceProcessingEnabled(true) }
            let fmt = inNode.outputFormat(forBus: 0)
            inNode.installTap(onBus: 0, bufferSize: 2048, format: fmt) { buf, _ in
                guard let ch = buf.floatChannelData else { return }
                let len = Int(buf.frameLength)
                var s = 0.0
                for i in 0..<len { s += Double(ch[0][i] * ch[0][i]) }
                lock.lock(); acc += s; cnt += len; lock.unlock()
            }
            e.prepare(); try e.start()
            let end = Date().addingTimeInterval(seconds)
            while Date() < end {
                Thread.sleep(forTimeInterval: 0.5)
                lock.lock(); let a = acc, n = cnt; acc = 0; cnt = 0; lock.unlock()
                lines.append(String(format: "%.2f %.1f %d", Date().timeIntervalSince1970, 10 * log10(a / Double(max(n, 1)) + 1e-12), n))
            }
            e.stop(); inNode.removeTap(onBus: 0)
        } catch { lines.append("FEHLER \(error)") }
        try? lines.joined(separator: "\n").write(to: out, atomically: true, encoding: .utf8)
    }

    /// Hört das Gegenüber einen noch, während der Transcriber aufnimmt? (Fehlerbericht 2026-10-19: Zoom + MacBook-
    /// Mikrofon + Transcriber mit Sprachverarbeitung → stumm.) `open -n ~/Applications/Transcriber.app --args
    /// --call-conflict-test ORDNER`: eine zweite Instanz spielt die Call-App (--mic-probe, je einmal mit und ohne
    /// Sprachverarbeitung), `say` spricht leise über die Lautsprecher; Phasen je 5 s: allein · Transcriber roh ·
    /// Pause · Transcriber mit Sprachverarbeitung. Ergebnis 2026-10-19: liest die Gegenstelle roh, bekommt sie ab dem
    /// Start der Sprachverarbeitung keine Samples mehr (−120 dB, auch nach dem Stopp); roh stört nicht; hat die
    /// Gegenstelle selbst Sprachverarbeitung, stört nichts. Pegel als Textdateien im ORDNER, Auswertung im app.log.
    static func callConflict(_ folder: URL) async {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let text = String(repeating: "Hallo, hier spricht der Selbsttest für Calls. Kannst du mich noch hören? ", count: 12)
        for probeVP in [true, false] {
            let name = probeVP ? "vp" : "roh"
            let out = folder.appendingPathComponent("probe-\(name).txt")
            try? FileManager.default.removeItem(at: out)
            let probe = Process()
            probe.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            probe.arguments = ["-n", Bundle.main.bundlePath, "--args", "--mic-probe", name, out.path, "26"]
            try? probe.run()
            let say = Process()
            say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            say.arguments = ["[[volm 0.4]] " + text]
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            try? say.run()
            var marks: [(String, Double)] = []
            func mark(_ m: String) { marks.append((m, Date().timeIntervalSince1970)) }
            func pause(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1e9)) }
            mark("allein"); await pause(5)
            for vp in [false, true] {                           // roh zuerst: Sprachverarbeitung stört danach dauerhaft
                let r = Recorder()
                do { try await r.start(deviceID: nil, systemAudio: false, voiceProcessing: vp, folder: folder) }
                catch { appLog("Call-Konflikt-Test: Start fehlgeschlagen: \(error.localizedDescription)") }
                mark(vp ? "transcriber-vp" : "transcriber-roh"); await pause(5)
                if let u = await r.stop() { try? FileManager.default.removeItem(at: u) }
                mark("pause"); await pause(3)
            }
            mark("ende")
            say.terminate()
            await pause(10)                                      // Probe läuft 26 s, dann liegt die Datei vor
            let rows = ((try? String(contentsOf: out, encoding: .utf8)) ?? "").split(separator: "\n").compactMap { l -> (Double, Double)? in
                let p = l.split(separator: " "); return p.count >= 2 ? Double(p[0]).flatMap { t in Double(p[1]).map { (t, $0) } } : nil }
            var summary: [String] = []
            for (k, m) in marks.enumerated() where k + 1 < marks.count {
                let lv = rows.filter { $0.0 > m.1 + 1 && $0.0 <= marks[k + 1].1 }.map(\.1)
                summary.append("\(m.0) \(lv.isEmpty ? "–" : String(format: "%.0f dB", lv.reduce(0, +) / Double(lv.count)))")
            }
            appLog("Call-Konflikt-Test (Gegenstelle \(probeVP ? "mit" : "ohne") Sprachverarbeitung): \(summary.joined(separator: " · "))")
        }
    }

    /// Die Wege der App selbst: `open -n ~/Applications/Transcriber.app --args --call-path-test ORDNER`.
    /// A: „Call aufnehmen“ (Control.start mit Call-Mikrofon) → ohne Sprachverarbeitung, die Gegenstelle (--mic-probe roh)
    /// hört weiter. B: Aufnahme mit Sprachverarbeitung (Einstellung), dann beginnt ein Call → Control.leaveVoiceProcessing
    /// stellt roh um; eine danach gestartete Gegenstelle hört. Testaufnahmen landen im Aufnahmeordner und werden gelöscht.
    @MainActor
    static func callPath(_ folder: URL) async {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let uid = Recorder.defaultInputDevice().flatMap { Recorder.deviceString($0, kAudioDevicePropertyDeviceUID) } ?? ""
        func pause(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1e9)) }
        func probe(_ name: String, _ seconds: Int) -> URL {
            let out = folder.appendingPathComponent("probe-\(name).txt")
            try? FileManager.default.removeItem(at: out)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            p.arguments = ["-n", Bundle.main.bundlePath, "--args", "--mic-probe", "roh", out.path, String(seconds)]
            try? p.run()
            return out
        }
        func level(_ out: URL, _ from: Double, _ to: Double) -> String {
            let rows = ((try? String(contentsOf: out, encoding: .utf8)) ?? "").split(separator: "\n").compactMap { l -> (Double, Double)? in
                let p = l.split(separator: " "); return p.count >= 2 ? Double(p[0]).flatMap { t in Double(p[1]).map { (t, $0) } } : nil }
            let lv = rows.filter { $0.0 > from && $0.0 <= to }.map(\.1)
            return lv.isEmpty ? "–" : String(format: "%.0f dB", lv.reduce(0, +) / Double(lv.count))
        }
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["[[volm 0.4]] " + String(repeating: "Hallo, hier spricht der Selbsttest für Calls. Kannst du mich noch hören? ", count: 14)]
        try? say.run()
        let r = Recorder()
        // A
        let pa = probe("a", 14)
        await pause(3)
        let a0 = Date().timeIntervalSince1970
        do { try await Control.start(r, callMic: uid) } catch { appLog("Call-Weg-Test A: Start fehlgeschlagen: \(error)") }
        let aVP = r.usesVoiceProcessing
        await pause(5)
        let a1 = Date().timeIntervalSince1970
        if let u = await r.stop() { try? FileManager.default.removeItem(at: u) }
        Control.callMic = nil
        await pause(8)
        appLog("Call-Weg-Test A (Call aufnehmen): Sprachverarbeitung \(aVP ? "AN – FEHLER" : "aus – ok"), Gegenstelle vorher \(level(pa, a0 - 2.5, a0)), während \(level(pa, a0 + 1, a1))")
        // B
        do { try await Control.start(r) } catch { appLog("Call-Weg-Test B: Start fehlgeschlagen: \(error)") }
        let bVP = r.usesVoiceProcessing
        await pause(3)
        Control.leaveVoiceProcessing(r)
        let bAfter = r.usesVoiceProcessing
        let pb = probe("b", 9)
        await pause(3)
        let b0 = Date().timeIntervalSince1970
        await pause(4)
        let b1 = Date().timeIntervalSince1970
        if let u = await r.stop() { try? FileManager.default.removeItem(at: u) }
        say.terminate()
        await pause(4)
        appLog("Call-Weg-Test B (Call während Aufnahme): vorher Sprachverarbeitung \(bVP ? "an" : "aus (Einstellung?)"), danach \(bAfter ? "AN – FEHLER" : "aus – ok"), neue Gegenstelle \(level(pb, b0, b1))")
    }

    /// Diktat während einer Aufnahme: `open -n ~/Applications/Transcriber.app --args --dictation-parallel-test ORDNER`.
    /// Je einmal Aufnahme roh (wie im Call) und mit Sprachverarbeitung (Treffen im Raum): 2 s Aufnahme allein, 3 s
    /// zusätzlich Diktat, 2 s danach. `say` spricht leise. Pegel der Aufnahme je Phase und des Diktats → app.log.
    /// `--own-mic`: Diktat mit eigenem Mikrofonzugriff statt aus der Aufnahme (so war es zuerst gemessen: roh gut, mit
    /// Sprachverarbeitung bekam das Diktat −62 dB und die Aufnahme änderte sich). Testaufnahmen werden gelöscht.
    @MainActor
    static func dictationParallel(_ folder: URL) async {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        func pause(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1e9)) }
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["[[volm 0.4]] " + String(repeating: "Hallo, hier spricht der Selbsttest für das Diktat. ", count: 16)]
        try? say.run()
        await pause(1)
        for vp in [false, true] {
            let r = Recorder()
            do { try await r.start(deviceID: nil, systemAudio: false, voiceProcessing: vp, folder: folder) }
            catch { appLog("Diktat-parallel-Test: Start fehlgeschlagen: \(error)"); continue }
            func meter(_ s: Double) async -> String {
                var v: [Float] = []
                for _ in 0..<Int(s * 10) { await pause(0.1); v.append(r.level) }
                let m = v.reduce(0, +) / Float(max(v.count, 1))
                return String(format: "%.0f dB", m * 60 - 60)
            }
            let before = await meter(2)
            let cap = DictationCapture()
            var err: String?
            let own = CommandLine.arguments.contains("--own-mic")
            cap.start(voiceProcessing: false, shared: own ? nil : { r.setMicFeed($0) }, onFirstBuffer: {}, onError: { err = $0 })
            let during = await meter(3)
            let samples = await cap.stop()
            let after = await meter(2)
            if let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
               let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(max(samples.count, 1))),
               let f = try? AVAudioFile(forWriting: folder.appendingPathComponent("diktat-\(vp ? "vp" : "roh").wav"), settings: fmt.settings) {
                b.frameLength = AVAudioFrameCount(samples.count)
                samples.withUnsafeBufferPointer { b.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
                try? f.write(from: b)                            // zum Nachprüfen: transcriber dictate DATEI
            }
            if let u = await r.stop() { try? FileManager.default.removeItem(at: u) }
            let rms = samples.isEmpty ? 0 : (samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
            appLog("Diktat-parallel-Test (\(own ? "eigenes Mikrofon" : "aus der Aufnahme"), Aufnahme \(vp ? "mit Sprachverarbeitung" : "roh")): Aufnahme vorher \(before), "
                   + "während Diktat \(during), danach \(after) · Diktat \(String(format: "%.1f", Double(samples.count) / 16000)) s, "
                   + String(format: "%.0f dB", 20 * log10(max(rms, 1e-6))) + (err.map { " · Fehler \($0)" } ?? ""))
            await pause(1)
        }
        say.terminate()
    }

    /// Beispieleinträge statt echter Aufnahmen (Screenshots für Website/Slack): `--args --ui-test --demo`.
    @MainActor
    static func demo(_ jobs: JobManager) {
        let en = Core.uiLanguage == "en"
        func job(_ title: String, _ min: Double, _ ago: Double, _ spk: [(String, String, String, Double, String?)]) -> Job {
            let j = Job(id: UUID().uuidString, source: URL(fileURLWithPath: "/demo/\(title).m4a"), started: Date().addingTimeInterval(-ago))
            j.state = .done; j.duration = min * 60
            j.speakers = spk.map { Speaker(letter: $0.0, display: $0.1, status: $0.2, score: nil, speechMin: $0.3,
                                           candidates: $0.4.map { [($0, 0.62)] } ?? []) }
            return j
        }
        let running = Job(id: UUID().uuidString, source: URL(fileURLWithPath: en ? "/demo/2026-10-14 16-00 Team meeting.m4a" : "/demo/2026-10-14 16-00 Teamrunde.m4a"),
                          started: Date())
        running.progress = 0.62; running.message = en ? "Speaker separation" : "Sprechertrennung"
        jobs.frozen = true
        jobs.jobs = [
            running,
            job(en ? "2026-10-14 14-03 Q4 budget planning" : "2026-10-14 14-03 Budgetplanung Q4", 42.3, 3600,
                [("A", "Alex Beispiel", "sicher", 12.4, nil), ("B", "Kim Exempel", "bestätigt", 9.8, nil),
                 ("C", "Sam Muster (?)", "vermutlich", 3.1, "Sam Muster")]),
            job(en ? "2026-10-14 11-30 Client call website relaunch" : "2026-10-14 11-30 Kundengespräch Website-Relaunch", 27.1, 7200,
                [("A", "Alex Beispiel", "sicher", 11.0, nil), ("B", en ? "Speaker B" : "Sprecher B", "unbekannt", 7.2, nil)]),
        ]
    }

    /// Oberfläche ansehen ohne Mausklick: `open -n ~/Applications/Transcriber.app --args --ui-test`
    /// Zeigt Panel und Einstellungs-Reiter kurz als Fenster, fotografiert sie (ScreenCaptureKit) → DATA/ui-*.png.
    @MainActor
    static func ui(recorder: Recorder, jobs: JobManager, dictation: Dictation, calls: CallDetector, updates: UpdateCheck) async {
        await jobs.loadNames()                                    // vor dem Bau der Ansichten (Exportblatt braucht die Namen)
        if CommandLine.arguments.contains("--demo") { demo(jobs) }
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
            ("stimmen", AnyView(VoicesView().frame(width: 620, height: 420))),
            ("fehler-melden", AnyView(ReportView())),
            ("stimmen-export", AnyView(PickVoices(title: String(localized: "Stimmen exportieren"), note: String(localized: "Je Person ein Stimmabdruck (256 Zahlen) mit Name – keine Aufnahmen, keine Titel oder Pfade. Stimmabdrücke sind biometrische Daten: nur mit Einwilligung der Personen weitergeben, möglichst über geschützte Wege. Die Datei ist nicht verschlüsselt."),
                                              items: jobs.knownNames.map { ($0, "") }, action: String(localized: "Exportieren …"), done: { _ in }, cancel: {}))),
        ]
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
