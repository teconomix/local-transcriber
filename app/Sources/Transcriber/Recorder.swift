import AVFoundation
import CoreAudio
import ScreenCaptureKit

/// Nimmt Mikrofon (Spur 1) und optional Systemton (Spur 2) in eine .m4a mit zwei AAC-Spuren auf.
/// Beide Quellen liefern Zeitstempel auf der Host-Uhr, daher genügt eine gemeinsame Writer-Sitzung.
/// Während der Aufnahme heißt die Datei „.<Name>.m4a“ (versteckt → der Ordnerwächter ignoriert sie).
final class Recorder: NSObject, ObservableObject, AVCaptureAudioDataOutputSampleBufferDelegate, SCStreamOutput, SCStreamDelegate {
    @Published var isRecording = false
    /// Zwischen Klick und laufender Aufnahme (Freigaben, Systemton, Sprachverarbeitung: ~1–2 s). Knopf gesperrt –
    /// sonst stoppte ein ungeduldiger zweiter Klick die gerade gestartete Aufnahme (Test im frischen Konto, 2026-10-10).
    @Published var isStarting = false
    @Published var level: Float = 0
    @Published var elapsed: TimeInterval = 0
    @Published var warning: String?

    private let queue = DispatchQueue(label: "recorder")
    private var session: AVCaptureSession?
    private var stream: SCStream?
    private var tap: AnyObject?                 // ProcessTap (macOS 14.2+), wenn „Systemton per Core Audio“ an ist
    private var sysRate = 48000.0
    private var engine: AVAudioEngine?
    private var writer: AVAssetWriter?
    private var micInput: AVAssetWriterInput?
    private var sysInput: AVAssetWriterInput?
    private var sessionStarted = false
    private var sessionStart = CMTime.invalid
    private var nextPTS: [ObjectIdentifier: CMTime] = [:]   // je Spur: wo das nächste Sample liegen müsste
    /// Nur für den Selbsttest (--gap-test): Systemton bis zu diesem Zeitpunkt verwerfen, als liefe noch nichts.
    var testDropSystemUntil: Date?
    private var tmpURL: URL?
    private var finalURL: URL?
    private var startDate = Date()
    private var timer: Timer?
    private var lastLevelUpdate = Date.distantPast

    static func microphones() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
    }

    private static func aac(channels: Int, rate: Double = 48000) -> [String: Any] {
        [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: channels, AVEncoderBitRateKey: 96000]
    }

    /// CoreAudio-Gerät zur AVCaptureDevice-UID (auf macOS ist uniqueID die CoreAudio-UID).
    static func audioDeviceID(uid: String) -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var cf = uid as CFString
        var dev = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let st = withUnsafePointer(to: &cf) {
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, UInt32(MemoryLayout<CFString>.size), $0, &size, &dev)
        }
        return st == noErr && dev != 0 ? dev : nil
    }

    static func defaultInputDevice() -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var dev = AudioDeviceID(0); var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        return AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev) == noErr ? dev : nil
    }

    func start(deviceID: String?, systemAudio: Bool, voiceProcessing: Bool, folder: URL) async throws {
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            throw NSError(domain: "Recorder", code: 1, userInfo: [NSLocalizedDescriptionKey: String(localized: "Kein Mikrofonzugriff (Systemeinstellungen › Datenschutz › Mikrofon)")])
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH-mm"
        let base = String(localized: "Aufnahme \(f.string(from: Date()))")   // RecordingTitle.defaultStamp erkennt de und en
        var name = base, n = 2        // zweite Aufnahme in derselben Minute: „… 2“ statt die erste zu überschreiben
        while FileManager.default.fileExists(atPath: folder.appendingPathComponent("\(name).m4a").path) { name = "\(base) \(n)"; n += 1 }
        finalURL = folder.appendingPathComponent("\(name).m4a")
        tmpURL = folder.appendingPathComponent(".\(name).m4a")
        try? FileManager.default.removeItem(at: tmpURL!)
        queue.sync { self.writer = nil; self.sessionStarted = false }   // Puffer vor dem Writer werden verworfen

        // Systemton zuerst: scheitert die Freigabe, wird ohne zweite Spur aufgenommen.
        var withSystem = false
        if systemAudio {
            do {
                // Process-Tap (nur Freigabe „Systemaudio“); scheitert er oder ist macOS älter als 14.2: ScreenCaptureKit.
                var tapped = false
                if #available(macOS 14.2, *) {
                    do { try startTapCapture(); tapped = true }
                    catch { appLog("Process-Tap fehlgeschlagen, nehme ScreenCaptureKit: \(error.localizedDescription)") }
                }
                if !tapped { try await startSystemCapture() }
                withSystem = true
            }
            catch { await MainActor.run { self.warning = String(localized: "Systemton nicht verfügbar (Bildschirmaufnahme-Freigabe?): \(error.localizedDescription)") } }
        }

        // Mikrofon: mit Apple-Sprachverarbeitung über AVAudioEngine, sonst roh über AVCaptureSession.
        var micRate = 48000.0
        if voiceProcessing {
            do { micRate = try startEngineMic(deviceID: deviceID) }
            catch {
                let msg = "Sprachverarbeitung nicht möglich, nehme roh auf: \(error) – Details in ~/.local/share/transcriber/app.log"
                appLog(msg)
                await MainActor.run { self.warning = msg }
                try startSessionMic(deviceID: deviceID)
            }
        } else {
            try startSessionMic(deviceID: deviceID)
        }

        let w = try AVAssetWriter(outputURL: tmpURL!, fileType: .m4a)
        let mic = AVAssetWriterInput(mediaType: .audio, outputSettings: Self.aac(channels: 1, rate: micRate))
        mic.expectsMediaDataInRealTime = true
        w.add(mic)
        var sys: AVAssetWriterInput?
        if withSystem {
            let s = AVAssetWriterInput(mediaType: .audio, outputSettings: Self.aac(channels: 1, rate: sysRate))
            s.expectsMediaDataInRealTime = true
            w.add(s); sys = s
        }
        queue.sync { self.writer = w; self.micInput = mic; self.sysInput = sys; self.sessionStarted = false }

        appLog("Aufnahme gestartet: \(name).m4a (\(withSystem ? "mit" : "ohne") Systemton)")
        await MainActor.run {
            self.startDate = Date(); self.elapsed = 0; self.isRecording = true
            let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.elapsed = Date().timeIntervalSince(self.startDate)
            }
            RunLoop.main.add(t, forMode: .common)
            self.timer = t
        }
    }

    private func startSessionMic(deviceID: String?) throws {
        let cs = AVCaptureSession()
        let dev = Self.microphones().first { $0.uniqueID == deviceID } ?? AVCaptureDevice.default(for: .audio)
        guard let dev else { throw NSError(domain: "Recorder", code: 2, userInfo: [NSLocalizedDescriptionKey: String(localized: "Kein Mikrofon gefunden")]) }
        let input = try AVCaptureDeviceInput(device: dev)
        guard cs.canAddInput(input) else { throw NSError(domain: "Recorder", code: 3, userInfo: [NSLocalizedDescriptionKey: String(localized: "Mikrofon nicht nutzbar")]) }
        cs.addInput(input)
        let out = AVCaptureAudioDataOutput()
        out.audioSettings = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 1,
                             AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false]
        out.setSampleBufferDelegate(self, queue: queue)
        cs.addOutput(out)
        cs.startRunning()
        session = cs
    }

    /// Apple-Sprachverarbeitung (Voice Processing I/O): automatische Pegelregelung, Rauschunterdrückung, Echounterdrückung.
    /// Andere Wiedergabe wird dabei normalerweise leiser geregelt („Ducking“) – hier auf das Minimum gestellt.
    /// Liefert die Abtastrate des Mikrofonsignals.
    private func startEngineMic(deviceID: String?) throws -> Double {
        let e = AVAudioEngine()
        let inNode = e.inputNode
        // Gerät nur setzen, wenn es nicht ohnehin das Standard-Eingabegerät ist (Voice Processing verträgt das schlecht).
        if let uid = deviceID, let dev = Self.audioDeviceID(uid: uid), dev != Self.defaultInputDevice() {
            do { try inNode.auAudioUnit.setDeviceID(dev) }
            catch { appLog("setDeviceID(\(uid)) fehlgeschlagen: \(error)"); throw error }
        }
        do { try inNode.setVoiceProcessingEnabled(true) }
        catch { appLog("setVoiceProcessingEnabled fehlgeschlagen: \(error)"); throw error }
        inNode.isVoiceProcessingAGCEnabled = true
        inNode.voiceProcessingOtherAudioDuckingConfiguration =
            AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
        // Mixer/Ausgang NICHT anfassen: eine Mixer→Ausgang-Verbindung nach dem Einschalten scheitert mit -10875
        // beim Initialisieren des Ausgangs (VP-Selbsttest 2026-10-09, Variante D).
        let fmt = inNode.outputFormat(forBus: 0)
        guard fmt.sampleRate > 0 else { throw NSError(domain: "Recorder", code: 5, userInfo: [NSLocalizedDescriptionKey: String(localized: "kein Eingangsformat")]) }
        inNode.installTap(onBus: 0, bufferSize: 4096, format: fmt) { [weak self] buf, when in
            guard let self, let sb = Self.monoSampleBuffer(buf, hostTime: when.hostTime) else { return }
            self.queue.async { self.append(sb, to: self.micInput); self.updateLevel(sb) }
        }
        e.prepare()
        do { try e.start() }
        catch { appLog("AVAudioEngine.start mit Voice Processing fehlgeschlagen: \(error)"); inNode.removeTap(onBus: 0); throw error }
        appLog("Voice Processing aktiv, Format \(fmt)")
        engine = e
        return fmt.sampleRate
    }

    /// Erster Kanal eines AVAudioPCMBuffer als Mono-Float-CMSampleBuffer mit Host-Zeitstempel (wie die anderen Quellen).
    static func monoSampleBuffer(_ buf: AVAudioPCMBuffer, hostTime: UInt64) -> CMSampleBuffer? {
        monoSampleBuffer(buf, pts: CMTimeConvertScale(CMClockMakeHostTimeFromSystemUnits(hostTime),
                                                      timescale: CMTimeScale(buf.format.sampleRate), method: .roundTowardZero))
    }

    static func monoSampleBuffer(_ buf: AVAudioPCMBuffer, pts: CMTime) -> CMSampleBuffer? {
        guard let ch = buf.floatChannelData, buf.frameLength > 0 else { return nil }
        let n = Int(buf.frameLength), sr = buf.format.sampleRate
        var asbd = AudioStreamBasicDescription(mSampleRate: sr, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 4, mFramesPerPacket: 1,
            mBytesPerFrame: 4, mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        var fmt: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                             magicCookie: nil, extensions: nil, formatDescriptionOut: &fmt) == noErr, let fmt else { return nil }
        var bb: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: n * 4, blockAllocator: nil,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: n * 4,
                                                 flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &bb) == noErr, let bb,
              CMBlockBufferReplaceDataBytes(with: ch[0], blockBuffer: bb, offsetIntoDestination: 0, dataLength: n * 4) == noErr
        else { return nil }
        var sb: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: bb, formatDescription: fmt, sampleCount: n,
                                                             presentationTimeStamp: pts, packetDescriptions: nil, sampleBufferOut: &sb)
        return sb
    }

    /// Systemton per Core-Audio-Process-Tap: alles außer Transcriber, ohne Bildschirmaufnahme-Freigabe (ProcessTap).
    @available(macOS 14.2, *)
    private func startTapCapture() throws {
        let t = ProcessTap()
        try t.start { [weak self] buf, host in
            guard let self, let sb = Self.monoSampleBuffer(buf, hostTime: host) else { return }
            if let d = self.testDropSystemUntil, Date() < d { return }
            self.queue.async { self.append(sb, to: self.sysInput) }
        }
        sysRate = t.format?.sampleRate ?? 48000
        tap = t
        appLog("Systemton per Process-Tap, \(t.format?.description ?? "?")")
    }

    private func startSystemCapture() async throws {
        sysRate = 48000
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw NSError(domain: "Recorder", code: 4) }
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let cfg = SCStreamConfiguration()
        cfg.capturesAudio = true
        cfg.excludesCurrentProcessAudio = true
        cfg.sampleRate = 48000
        cfg.channelCount = 1
        cfg.width = 2; cfg.height = 2                       // Bild wird nicht gebraucht
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try await s.startCapture()
        stream = s
    }

    func stop() async -> URL? {
        session?.stopRunning(); session = nil
        if let e = engine { e.inputNode.removeTap(onBus: 0); e.stop(); engine = nil }
        if let s = stream { try? await s.stopCapture(); stream = nil }
        if #available(macOS 14.2, *), let t = tap as? ProcessTap { t.stop(); tap = nil }
        await MainActor.run { self.timer?.invalidate(); self.isRecording = false; self.level = 0 }
        let (w, mic, sys, started): (AVAssetWriter?, AVAssetWriterInput?, AVAssetWriterInput?, Bool) =
            queue.sync { let r = (writer, micInput, sysInput, sessionStarted); writer = nil; micInput = nil; sysInput = nil; return r }
        guard let w, started else { return nil }
        mic?.markAsFinished(); sys?.markAsFinished()
        await w.finishWriting()
        guard w.status == .completed, let tmp = tmpURL, let fin = finalURL else {
            let msg = String(localized: "Aufnahme fehlgeschlagen: \(w.error?.localizedDescription ?? String(localized: "unbekannt"))")
            await MainActor.run { self.warning = msg }
            return nil
        }
        appLog(String(format: "Aufnahme beendet: %@ (%.0f s)", fin.lastPathComponent, Date().timeIntervalSince(startDate)))
        do { try FileManager.default.moveItem(at: tmp, to: fin) } catch {
            appLog("Aufnahme nicht umbenannt (\(error.localizedDescription)), bleibt unter \(tmp.lastPathComponent)")
            return tmp
        }
        return fin
    }

    // Beide Quellen landen hier, auf `queue`.
    /// AAC-Spuren sind eine lückenlose Folge von Samples: Zeitlücken in den Zeitstempeln schiebt AVAssetWriter einfach
    /// zusammen. Der Process-Tap liefert aber nur, solange irgendetwas abspielt – startete ein Video erst nach 35 s, lag
    /// es in der Datei bei 0 s über der eigenen Sprache (Test im frischen Konto, 2026-10-10). Deshalb jede Lücke
    /// (Spurbeginn nach Aufnahmebeginn, Pausen) mit Stille füllen: Sekunde x liegt in beiden Spuren an derselben Stelle.
    private func append(_ sb: CMSampleBuffer, to input: AVAssetWriterInput?) {
        guard let w = writer, let input, CMSampleBufferDataIsReady(sb) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        if !sessionStarted {
            guard w.startWriting() else { return }
            w.startSession(atSourceTime: pts)
            sessionStarted = true; sessionStart = pts; nextPTS = [:]
        }
        guard w.status == .writing else { return }
        let key = ObjectIdentifier(input)
        let rate = CMAudioFormatDescriptionGetStreamBasicDescription(CMSampleBufferGetFormatDescription(sb)!)?.pointee.mSampleRate ?? 48000
        var next = nextPTS[key] ?? sessionStart
        let gap = CMTimeGetSeconds(CMTimeSubtract(pts, next))
        if gap > Self.gapTolerance && gap < Self.maxGap {
            next = fillSilence(input, from: next, to: pts, rate: rate)
            nextPTS[key] = next          // immer merken, wie weit gefüllt ist – sonst füllt der nächste Puffer alles erneut
        }
        // Puffer nicht verwerfen, nur weil der Kodierer gerade beschäftigt ist; fällt er doch weg, entsteht eine Lücke,
        // die der nächste Puffer mit Stille schließt (nextPTS bleibt dann stehen).
        guard Self.waitReady(input) else { appLog("Aufnahme: Puffer verworfen (Kodierer ausgelastet)"); return }
        input.append(sb)
        let end = CMTimeAdd(pts, CMTime(value: CMTimeValue(CMSampleBufferGetNumSamples(sb)), timescale: CMTimeScale(rate)))
        nextPTS[key] = CMTimeMaximum(next, end)
    }

    private static let gapTolerance = 0.05      // kleiner Versatz (Takt, Puffergrenzen) ist normal, nur echte Lücken füllen
    private static let maxGap = 12.0 * 3600     // Schutz gegen unsinnige Zeitstempel

    /// Kurz warten, bis der Kodierer wieder annimmt (läuft auf `queue`, nicht auf einem Audio-Thread). Ohne das brach
    /// eine 49-s-Lücke nach einigen Stücken ab und wurde bei jedem folgenden Puffer erneut gefüllt → 1 h Stille (2026-10-10).
    private static func waitReady(_ input: AVAssetWriterInput, timeout: TimeInterval = 2) -> Bool {
        let until = Date().addingTimeInterval(timeout)
        while !input.isReadyForMoreMediaData {
            if Date() > until { return false }
            usleep(2000)
        }
        return true
    }

    /// Stille von `from` bis `to` in Stücken von höchstens 1 s; liefert, bis wohin tatsächlich gefüllt wurde.
    private func fillSilence(_ input: AVAssetWriterInput, from: CMTime, to: CMTime, rate: Double) -> CMTime {
        guard let fmt = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1) else { return from }
        var t = from
        while CMTimeCompare(t, to) < 0 {
            let frames = min(Int(rate), Int((CMTimeGetSeconds(CMTimeSubtract(to, t)) * rate).rounded()))
            guard frames > 0, let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(frames)) else { break }
            buf.frameLength = AVAudioFrameCount(frames)
            buf.floatChannelData![0].update(repeating: 0, count: frames)
            let at = CMTimeConvertScale(t, timescale: CMTimeScale(rate), method: .roundHalfAwayFromZero)
            guard let sil = Self.monoSampleBuffer(buf, pts: at), Self.waitReady(input) else { break }
            input.append(sil)
            t = CMTimeAdd(at, CMTime(value: CMTimeValue(frames), timescale: CMTimeScale(rate)))
        }
        let want = CMTimeGetSeconds(CMTimeSubtract(to, from)), done = CMTimeGetSeconds(CMTimeSubtract(t, from))
        if want >= 1 || done + 0.01 < want {
            appLog(String(format: "Aufnahme: %.1f s Stille in %@ eingefügt", done, input === sysInput ? "Systemton-Spur" : "Mikrofon-Spur")
                   + (done + 0.01 < want ? String(format: " (von %.1f s)", want) : ""))
        }
        return t
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from connection: AVCaptureConnection) {
        append(sb, to: micInput)
        updateLevel(sb)
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        if type == .audio { append(sb, to: sysInput) }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { self.warning = String(localized: "Systemton abgebrochen: \(error.localizedDescription)") }
    }

    private func updateLevel(_ sb: CMSampleBuffer) {
        guard Date().timeIntervalSince(lastLevelUpdate) > 0.1, let bb = CMSampleBufferGetDataBuffer(sb) else { return }
        lastLevelUpdate = Date()
        var len = 0; var ptr: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(bb, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &len, dataPointerOut: &ptr) == noErr, let ptr else { return }
        let n = len / MemoryLayout<Float>.size
        guard n > 0 else { return }
        let rms = ptr.withMemoryRebound(to: Float.self, capacity: n) { p -> Float in
            var s: Float = 0; for i in 0..<n { s += p[i] * p[i] }; return (s / Float(n)).squareRoot()
        }
        let db = 20 * log10(max(rms, 1e-6))                  // −60 dB … 0 dB → 0 … 1
        DispatchQueue.main.async { self.level = max(0, min(1, (db + 60) / 60)) }
    }
}
