import AppKit
import ApplicationServices
import AVFoundation
import SwiftUI

/// Diktat überall: Taste halten → sprechen → loslassen → Text steht an der Schreibmarke der aktiven App.
/// Aufnahme nur im Speicher, Erkennung im dauerhaft laufenden Python-Dienst (`transcriber dictate-server`,
/// Unix-Socket, Protokoll in transcriber/dictate.py). Einfügen über Zwischenablage + ⌘V; die vorherige
/// Zwischenablage kommt danach zurück. Neben der Schreibmarke zeigt ein kleines Symbol den Zustand.
/// Braucht die Freigabe „Bedienungshilfen“ (Taste beobachten, Schreibmarke finden, ⌘V senden).
@MainActor
final class Dictation: ObservableObject {
    enum State: Equatable { case idle, starting, recording, transcribing }
    @Published var state: State = .idle
    @Published var cleaning = false          // laufendes Diktat mit KI-Aufräumen (zweite Taste)
    @Published var trusted = AXIsProcessTrusted()
    @Published var lastInfo: String?
    @Published var lastError: String?

    /// Taste zum Halten. Nur Modifikatortasten: sie tippen nichts, solange sie allein gedrückt sind.
    static let keys: [(id: String, label: String, code: UInt16, flag: NSEvent.ModifierFlags)] = [
        ("rcmd", "rechte ⌘", 54, .command),
        ("ropt", "rechte ⌥", 61, .option),
        ("rctrl", "rechte ⌃", 62, .control),
        ("fn", "fn / 🌐", 63, .function),
    ]
    nonisolated static let socket = Core.data.appendingPathComponent("dictate.sock").path
    static let minHold = 0.3                 // kürzer = versehentliches Antippen, wird verworfen

    var enabled: Bool { UserDefaults.standard.object(forKey: "dictation") as? Bool ?? false }
    var keyID: String { UserDefaults.standard.string(forKey: "dictationKey") ?? "rcmd" }
    /// Zweite Taste: wie Diktat, danach leichtes Aufräumen per Apple-Modell (DictationCleanup). "off" = aus.
    var cleanKeyID: String { UserDefaults.standard.string(forKey: "dictationCleanKey") ?? "ropt" }
    var screenContext: Bool { UserDefaults.standard.object(forKey: "dictationScreenContext") as? Bool ?? true }
    var language: String { UserDefaults.standard.string(forKey: "language") ?? "de" }
    /// Standard aus: Apples Sprachverarbeitung braucht ~1 s zum Starten (gemessen 670–1076 ms gegenüber ~160 ms).
    var voiceProcessing: Bool { UserDefaults.standard.object(forKey: "dictationVP") as? Bool ?? false }
    var sound: Bool { UserDefaults.standard.object(forKey: "dictationSound") as? Bool ?? true }
    var showIndicator: Bool { UserDefaults.standard.object(forKey: "dictationIndicator") as? Bool ?? true }
    /// Gesetzt von außen: während einer Meeting-Aufnahme ist das Mikrofon belegt.
    var micBusy: () -> Bool = { false }

    private var monitors: [Any] = []
    private var pressedAt: Date?
    private var cancelled = false
    private var activeKey: UInt16?
    private var screenTask: Task<String?, Never>?
    private var server: Process?
    private var trustTimer: Timer?
    private let capture = DictationCapture()
    private lazy var indicator = DictationIndicator(model: self)

    init() {
        // Selbsttests (--…-test) beenden sich per exit(): dort keinen Dienst starten, er bliebe verwaist zurück.
        if enabled && !CommandLine.arguments.contains(where: { $0.hasSuffix("-test") }) { activate() }
        // Der Dienst ist ein Kindprozess, überlebt das Beenden der App aber sonst (und hielte die Modelle im Speicher).
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.server?.terminate() }
        }
    }

    // MARK: Ein/Aus

    func activate() {
        trusted = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        installMonitors()
        startServer()
        capture.prepare(voiceProcessing: voiceProcessing)
        if cleanKeyID != "off" { DictationCleanup.prewarm(); if screenContext { ScreenContext.prewarm() } }
        // Freigabe wird in den Systemeinstellungen erteilt, während die App läuft: nachschauen und Beobachter neu setzen.
        trustTimer?.invalidate()
        if !trusted {
            let t = Timer(timeInterval: 2, repeats: true) { [weak self] t in
                Task { @MainActor in
                    guard let self else { return t.invalidate() }
                    if AXIsProcessTrusted() { self.trusted = true; self.installMonitors(); t.invalidate() }
                }
            }
            RunLoop.main.add(t, forMode: .common)
            trustTimer = t
        }
    }

    func deactivate() {
        trustTimer?.invalidate()
        removeMonitors()
        abort()
        capture.shutdown()
        server?.terminate(); server = nil
    }

    /// Nach Umschalten der Sprachverarbeitung: Engine passend neu vorbereiten.
    func settingsChanged() { if enabled { capture.prepare(voiceProcessing: voiceProcessing) } }

    static func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    // MARK: Taste

    private func installMonitors() {
        removeMonitors()
        let flags: (NSEvent) -> Void = { [weak self] e in Task { @MainActor in self?.flagsChanged(e) } }
        let keyDown: (NSEvent) -> Void = { [weak self] _ in Task { @MainActor in self?.otherKey() } }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: flags) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: keyDown) { monitors.append(m) }
        // Globale Beobachter sehen nichts, solange die eigene App vorn ist.
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { flags($0); return $0 } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { keyDown($0); return $0 } as Any)
    }

    private func removeMonitors() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors = []
    }

    private func flagsChanged(_ e: NSEvent) {
        let main = Self.keys.first { $0.id == keyID }
        let clean = cleanKeyID == keyID ? nil : Self.keys.first { $0.id == cleanKeyID }
        if let key = [main, clean].compactMap({ $0 }).first(where: { $0.code == e.keyCode }), activeKey == nil || activeKey == key.code {
            if e.modifierFlags.contains(key.flag) { keyDown(key.code, clean: key.code == clean?.code) } else { keyUp() }
        } else if pressedAt != nil {
            cancelled = true                  // weitere Modifikatortaste dazu → Tastenkürzel, kein Diktat
            abort()
        }
    }

    private func otherKey() {
        guard pressedAt != nil else { return }
        cancelled = true                      // z. B. ⌘C: Tastenkürzel, kein Diktat
        abort()
    }

    private func keyDown(_ code: UInt16, clean: Bool) {
        guard pressedAt == nil, state == .idle else { return }
        guard !micBusy() else { NSSound.beep(); lastError = "Mikrofon belegt (Meeting-Aufnahme läuft)"; return }
        pressedAt = Date(); cancelled = false; lastError = nil; activeKey = code; cleaning = clean
        // Bildschirmtext jetzt lesen (parallel zur Aufnahme), solange noch das Fenster vorn ist, in das diktiert wird.
        screenTask = clean && screenContext && DictationCleanup.unavailableReason == nil ? Task { await ScreenContext.capture() } : nil
        state = .starting
        if showIndicator { indicator.show() }

        let t0 = Date()
        capture.start(voiceProcessing: voiceProcessing,
                      onFirstBuffer: { [weak self] in
                          Task { @MainActor in
                              guard let self, self.state == .starting else { return }
                              appLog(String(format: "Diktat: erster Puffer nach %.0f ms", Date().timeIntervalSince(t0) * 1000))
                              self.state = .recording
                              if self.sound { NSSound(named: "Tink")?.play() }   // jetzt sprechen
                          }
                      },
                      onError: { [weak self] msg in
                          Task { @MainActor in
                              guard let self else { return }
                              self.lastError = msg; appLog("Diktat: \(msg)"); NSSound.beep(); self.abort()
                          }
                      })
    }

    private func keyUp() {
        guard let t = pressedAt else { return }
        pressedAt = nil; activeKey = nil
        guard state == .starting || state == .recording else { return }
        if cancelled || Date().timeIntervalSince(t) < Self.minHold { abort(); return }
        state = .transcribing
        let lang = language, clean = cleaning, screenTask = screenTask
        self.screenTask = nil
        Task {
            let samples = await capture.stop()
            let res = samples.isEmpty ? .success(Result(text: "", ms: 0, audioS: 0)) : await recognize(samples, language: lang)
            var text = (try? res.get())?.text ?? "", note = ""
            if clean, !text.isEmpty { (text, note) = await DictationCleanup.clean(text, screen: await ScreenContext.value(of: screenTask)) }
            indicator.hide()
            switch res {
            case .success(let r):
                if !text.isEmpty { Self.insert(text + " ") }
                lastInfo = String(format: "%.1f s → %d ms", r.audioS, r.ms) + (text.isEmpty ? " (nichts erkannt)" : "")
                    + (note.isEmpty ? "" : ", \(note)")
            case .failure(let err):
                lastError = err.localizedDescription
                appLog("Diktat: \(err.localizedDescription)")
                NSSound.beep()
            }
            state = .idle
        }
    }

    /// Abbrechen ohne Ergebnis (Tastenkürzel, Fehler, Ausschalten).
    private func abort() {
        pressedAt = nil; activeKey = nil
        screenTask?.cancel(); screenTask = nil
        if state == .starting || state == .recording { Task { _ = await capture.stop() } }
        indicator.hide()
        state = .idle
    }

    // MARK: Dienst

    private func startServer() {
        if let s = server, s.isRunning { return }
        let p = Core.process(["dictate-server"])
        let log = Core.data.appendingPathComponent("dictate.log")
        if !FileManager.default.fileExists(atPath: log.path) { FileManager.default.createFile(atPath: log.path, contents: nil) }
        if let h = try? FileHandle(forWritingTo: log) { h.seekToEndOfFile(); p.standardError = h; p.standardOutput = h }
        do { try p.run(); server = p } catch { lastError = "Diktat-Dienst startet nicht: \(error.localizedDescription)" }
    }

    struct Result { let text: String; let ms: Int; let audioS: Double }

    /// Dienst evtl. noch beim Laden (Kaltstart ~1,5 s) oder abgestürzt: einmal neu starten, bis 10 s warten.
    private func recognize(_ samples: [Float], language: String) async -> Swift.Result<Result, Error> {
        for attempt in 0..<20 {
            do { return .success(try await Task.detached { try Self.request(samples, language: language) }.value) }
            catch let e as SocketError where e.connect {
                if attempt == 0 { startServer() }
                try? await Task.sleep(nanoseconds: 500_000_000)
            } catch { return .failure(error) }
        }
        return .failure(SocketError(msg: "Diktat-Dienst nicht erreichbar (Protokoll: ~/.local/share/transcriber/dictate.log)", connect: true))
    }

    struct SocketError: LocalizedError { let msg: String; let connect: Bool; var errorDescription: String? { msg } }
    nonisolated static func err(_ m: String) -> SocketError { SocketError(msg: m, connect: false) }

    nonisolated static func connectSocket() throws -> Int32 {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw err("socket() fehlgeschlagen") }
        var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
        let path = Array(socket.utf8CString)
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            for (i, c) in path.prefix(buf.count - 1).enumerated() { buf[i] = UInt8(bitPattern: c) }
        }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard ok == 0 else { close(fd); throw SocketError(msg: "Diktat-Dienst nicht erreichbar", connect: true) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }

    nonisolated static func writeAll(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { raw in
            var off = 0
            while off < raw.count {
                let n = write(fd, raw.baseAddress! + off, raw.count - off)
                guard n > 0 else { throw err("Senden an den Diktat-Dienst fehlgeschlagen") }
                off += n
            }
        }
    }

    nonisolated static func floats(_ s: [Float]) -> Data { s.withUnsafeBufferPointer { Data(buffer: $0) } }

    nonisolated static func parseFinal(_ line: Data) throws -> Result {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { throw err("keine Antwort vom Diktat-Dienst") }
        if let e = obj["error"] as? String { throw err("Diktat-Dienst: \(e)") }
        return Result(text: obj["text"] as? String ?? "", ms: obj["ms"] as? Int ?? 0, audioS: obj["audio_s"] as? Double ?? 0)
    }

    /// Eine Anfrage am Stück (blockierend, läuft abseits des Hauptthreads).
    nonisolated static func request(_ samples: [Float], language: String) throws -> Result {
        let fd = try connectSocket()
        defer { close(fd) }
        var tv = timeval(tv_sec: 120, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        try writeAll(fd, Data("{\"language\":\"\(language)\",\"samples\":\(samples.count)}\n".utf8) + floats(samples))
        var reply = Data(); var byte: UInt8 = 0
        while read(fd, &byte, 1) == 1 { if byte == 10 { break }; reply.append(byte) }
        return try parseFinal(reply)
    }

    // MARK: Einfügen

    /// Text über die Zwischenablage einfügen und die vorherige Zwischenablage danach zurücklegen.
    /// Als „vorübergehend“ markiert, damit Zwischenablage-Verlaufsprogramme das Diktat nicht speichern.
    static func insert(_ text: String) {
        let pb = NSPasteboard.general
        let saved: [NSPasteboardItem] = (pb.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for t in item.types { if let d = item.data(forType: t) { copy.setData(d, forType: t) } }
            return copy
        }
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        item.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType"))
        pb.writeObjects([item])
        let ours = pb.changeCount

        let src = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: down)   // 9 = V (ANSI und QWERTZ)
            e?.flags = .maskCommand
            e?.post(tap: .cghidEventTap)
        }
        // Zurücklegen erst, wenn die Ziel-App eingefügt hat. Hat inzwischen jemand anderes kopiert: nicht überschreiben.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            guard pb.changeCount == ours else { return }
            pb.clearContents()
            if !saved.isEmpty { pb.writeObjects(saved) }
        }
    }
}

/// Mikrofon → 16 kHz mono im Speicher.
///
/// Muster VoiceInk: Die Engine wird vorab aufgebaut (Tap installiert, prepare) und zwischen Diktaten nur pausiert.
/// Gemessen 2026-10-10: erster Puffer nach 153–165 ms statt 180–350 ms (kalt) bzw. ~1 s (mit Sprachverarbeitung);
/// im pausierten Zustand läuft das Gerät nicht (DeviceIsRunningSomewhere = 0) → kein oranger Punkt.
/// Start/Stopp laufen nacheinander auf `ctl`: der Start darf weder den Hauptthread blockieren noch von einem schnellen
/// Loslassen überholt werden.
final class DictationCapture: @unchecked Sendable {
    private let ctl = DispatchQueue(label: "dictation.capture")
    private let lock = NSLock()
    // nur auf ctl
    private var engine: AVAudioEngine?
    private var engineVP = false
    private var stale = false
    private var observer: NSObjectProtocol?
    private var mono: AVAudioFormat?
    // unter lock (Tap-Thread)
    private var active = false
    private var gotBuffer = false
    private var converter: AVAudioConverter?
    private var all: [Float] = []
    private var onFirst: (() -> Void)?
    private let outFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!

    /// Engine aufbauen, ohne das Mikrofon einzuschalten.
    func prepare(voiceProcessing: Bool) {
        ctl.async { [self] in
            guard !isActive() else { return }
            do { try build(voiceProcessing: voiceProcessing) } catch { appLog("Diktat: Vorbereiten fehlgeschlagen: \(error)") }
        }
    }

    func shutdown() { ctl.async { [self] in teardown() } }

    private func isActive() -> Bool { lock.lock(); defer { lock.unlock() }; return active }
    private func hasBuffer() -> Bool { lock.lock(); defer { lock.unlock() }; return gotBuffer }

    private func build(voiceProcessing: Bool) throws {
        teardown()
        let e = AVAudioEngine()
        let inNode = e.inputNode
        if voiceProcessing {
            try inNode.setVoiceProcessingEnabled(true)
            inNode.isVoiceProcessingAGCEnabled = true
            inNode.voiceProcessingOtherAudioDuckingConfiguration =
                AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
        }
        let fmt = inNode.outputFormat(forBus: 0)
        guard fmt.sampleRate > 0,
              let m = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: fmt.sampleRate, channels: 1, interleaved: false)
        else { throw NSError(domain: "Dictation", code: 1, userInfo: [NSLocalizedDescriptionKey: "kein Eingangsformat"]) }
        inNode.installTap(onBus: 0, bufferSize: 1024, format: fmt) { [weak self] buf, _ in self?.handle(buf, mono: m) }
        e.prepare()
        // Gerätewechsel (Headset an/ab, Standardgerät geändert): beim nächsten Start neu aufbauen.
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: e, queue: nil) { [weak self] _ in
            self?.ctl.async { self?.stale = true }
        }
        engine = e; engineVP = voiceProcessing; mono = m; stale = false
    }

    private func teardown() {
        if let o = observer { NotificationCenter.default.removeObserver(o); observer = nil }
        if let e = engine { e.inputNode.removeTap(onBus: 0); e.stop(); engine = nil }
    }

    func start(voiceProcessing: Bool, onFirstBuffer: @escaping () -> Void, onError: @escaping (String) -> Void) {
        ctl.async { [self] in
            // Selten kommt nach dem Start kein einziger Puffer (Latenztest 2026-10-10): dann einmal neu aufbauen.
            for attempt in 0..<2 {
                do {
                    if engine == nil || stale || engineVP != voiceProcessing || attempt > 0 { try build(voiceProcessing: voiceProcessing) }
                    guard let m = mono, let conv = AVAudioConverter(from: m, to: outFmt) else { throw NSError(domain: "Dictation", code: 2) }
                    lock.lock()
                    all = []; gotBuffer = false; converter = conv
                    onFirst = onFirstBuffer; active = true
                    lock.unlock()
                    try engine?.start()
                } catch { return onError("Aufnahme nicht möglich: \(error.localizedDescription)") }
                for _ in 0..<20 { if hasBuffer() { return }; Thread.sleep(forTimeInterval: 0.05) }
                guard isActive() else { return }               // inzwischen losgelassen
                appLog("Diktat: nach 1 s kein Audiopuffer" + (attempt == 0 ? ", baue Mikrofon neu auf" : ""))
            }
            onError("Mikrofon liefert keinen Ton")
        }
    }

    private func handle(_ buf: AVAudioPCMBuffer, mono m: AVAudioFormat) {
        guard let ch = buf.floatChannelData, buf.frameLength > 0,
              let mb = AVAudioPCMBuffer(pcmFormat: m, frameCapacity: buf.frameLength) else { return }
        mb.frameLength = buf.frameLength
        mb.floatChannelData![0].update(from: ch[0], count: Int(buf.frameLength))   // erster Kanal
        lock.lock()
        guard active else { lock.unlock(); return }
        let first = !gotBuffer; gotBuffer = true
        all += convert(mb, end: false)
        let fb = onFirst
        lock.unlock()
        if first { fb?() }
    }

    /// Unter `lock` aufrufen. Der Konverter behält seinen Zustand zwischen den Puffern (.noDataNow statt Ende).
    private func convert(_ buf: AVAudioPCMBuffer?, end: Bool) -> [Float] {
        guard let conv = converter else { return [] }
        let cap = AVAudioFrameCount(Double(buf?.frameLength ?? 0) * 16000 / conv.inputFormat.sampleRate) + 512
        guard let out = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: cap) else { return [] }
        var fed = false
        var error: NSError?
        conv.convert(to: out, error: &error) { _, status in
            if let buf, !fed { fed = true; status.pointee = .haveData; return buf }
            status.pointee = end ? .endOfStream : .noDataNow
            return nil
        }
        if let error { appLog("Diktat: Umrechnung auf 16 kHz fehlgeschlagen: \(error)"); return [] }
        return Array(UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength)))
    }

    /// Beendet die Aufnahme (wartet einen laufenden Start ab) und liefert alles.
    /// Die Engine wird nur pausiert: Mikrofon aus, Aufbau bleibt für das nächste Diktat.
    func stop() async -> [Float] {
        await withCheckedContinuation { cont in
            ctl.async { [self] in
                engine?.pause()
                lock.lock()
                if active { all += convert(nil, end: true) }
                let result = all
                all = []; onFirst = nil; converter = nil; active = false
                lock.unlock()
                cont.resume(returning: result)
            }
        }
    }
}

/// Kleines Symbol neben der Schreibmarke (wie MacWhisper): Mikrofon startet → nimmt auf → erkennt.
/// Position über die Bedienungshilfen: Schreibmarke, sonst fokussiertes Feld, sonst Mauszeiger. Electron-Apps
/// (Slack, VS Code, Claude) geben die Schreibmarke oft nicht heraus. Das Fenster nimmt nie den Fokus
/// (sonst landete der Text im falschen Fenster) und lässt Mausklicks durch.
@MainActor
final class DictationIndicator {
    private var panel: NSPanel?
    private unowned let model: Dictation
    nonisolated private static let size = NSSize(width: 34, height: 34)

    init(model: Dictation) { self.model = model }

    func show() {
        if panel == nil {
            let p = NSPanel(contentRect: NSRect(origin: .zero, size: Self.size), styleMask: [.nonactivatingPanel, .borderless],
                            backing: .buffered, defer: false)
            p.level = .statusBar
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = true
            p.ignoresMouseEvents = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            p.contentView = NSHostingView(rootView: DictationIndicatorView().environmentObject(model))
            panel = p
        }
        let mouse = NSEvent.mouseLocation
        // Bedienungshilfen-Abfrage kann bei hängender Ziel-App kurz blockieren: abseits des Hauptthreads.
        Task.detached {
            let (origin, source) = Self.position(mouse: mouse)
            await MainActor.run {
                guard let p = self.panel, self.model.state != .idle else { return }
                p.setFrameOrigin(origin)
                p.orderFrontRegardless()
                appLog("Diktat: Symbol an \(source)")
            }
        }
    }

    func hide() { panel?.orderOut(nil) }

    /// Linke untere Ecke des Symbols in Bildschirmkoordinaten (Ursprung unten links).
    nonisolated static func position(mouse: NSPoint) -> (NSPoint, String) {
        let s = size
        var origin: NSPoint, source: String
        if let r = caretRect(caretOnly: true) {
            origin = NSPoint(x: r.maxX + 6, y: r.midY - s.height / 2); source = "Schreibmarke"
        } else if let r = caretRect(caretOnly: false) {
            origin = NSPoint(x: r.minX, y: r.maxY + 4); source = "Eingabefeld"
        } else {
            origin = NSPoint(x: mouse.x + 14, y: mouse.y - 14 - s.height); source = "Mauszeiger"
        }
        // Auf dem Bildschirm halten.
        let pt = NSPoint(x: origin.x + s.width / 2, y: origin.y + s.height / 2)
        if let f = (NSScreen.screens.first { $0.frame.contains(pt) } ?? NSScreen.main)?.visibleFrame {
            origin.x = min(max(origin.x, f.minX + 4), f.maxX - s.width - 4)
            origin.y = min(max(origin.y, f.minY + 4), f.maxY - s.height - 4)
        }
        return (origin, source)
    }

    /// Schreibmarke (caretOnly) bzw. Rahmen des fokussierten Elements, umgerechnet von Bedienungshilfen-Koordinaten
    /// (Ursprung oben links am Hauptbildschirm) nach AppKit (unten links).
    nonisolated static func caretRect(caretOnly: Bool) -> NSRect? {
        let sys = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(sys, 0.15)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &ref) == .success, let ref,
              CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        let el = ref as! AXUIElement
        var r = CGRect.zero
        if caretOnly {
            var range: CFTypeRef?, bounds: CFTypeRef?
            guard AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &range) == .success, let range,
                  AXUIElementCopyParameterizedAttributeValue(el, kAXBoundsForRangeParameterizedAttribute as CFString, range, &bounds) == .success,
                  let bounds, CFGetTypeID(bounds) == AXValueGetTypeID(),
                  AXValueGetValue(bounds as! AXValue, .cgRect, &r), r.height > 0, r.origin != .zero else { return nil }
        } else {
            var pos: CFTypeRef?, size: CFTypeRef?
            var p = CGPoint.zero, sz = CGSize.zero
            guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &pos) == .success, let pos,
                  AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &size) == .success, let size,
                  AXValueGetValue(pos as! AXValue, .cgPoint, &p), AXValueGetValue(size as! AXValue, .cgSize, &sz),
                  sz.width > 0, sz.height > 0 else { return nil }
            r = CGRect(origin: p, size: sz)
        }
        guard let h = NSScreen.screens.first?.frame.height else { return nil }
        return NSRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height)
    }
}

struct DictationIndicatorView: View {
    @EnvironmentObject var d: Dictation
    var body: some View {
        ZStack {
            Circle().fill(.regularMaterial)
            switch d.state {
            case .recording:
                Image(systemName: "mic.fill").foregroundStyle(.red).symbolEffect(.pulse)
            case .transcribing where d.cleaning:
                Image(systemName: "sparkles").foregroundStyle(.purple).symbolEffect(.variableColor.iterative)
            case .transcribing:
                Image(systemName: "waveform").foregroundStyle(.secondary).symbolEffect(.variableColor.iterative)
            default:
                Image(systemName: "mic").foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 15, weight: .semibold))
        .frame(width: 34, height: 34)
    }
}
