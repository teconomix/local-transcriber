import AVFoundation
import CoreAudio

/// Systemton per Core-Audio-Process-Tap (macOS 14.2+; Abgriff nach Bundle-ID ab macOS 26) statt ScreenCaptureKit.
/// Vorteil: braucht nur die Freigabe „Nur Systemaudio aufnehmen“ (NSAudioCaptureUsageDescription), nicht
/// „Bildschirmaufnahme“ – wichtig für die Weitergabe. Liefert Mono-Puffer mit Host-Zeitstempel wie die anderen Quellen.
/// Aufbau laut CoreAudio-Headern: CATapDescription → AudioHardwareCreateProcessTap → privates Aggregatgerät mit dem Tap
/// als Sub-Tap → IOProc liest die Eingabe.
@available(macOS 14.2, *)
final class ProcessTap {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "processtap")
    private(set) var format: AVAudioFormat?

    struct Failure: LocalizedError {
        let msg: String
        var errorDescription: String? { msg }
    }

    /// bundleIDs: nur diese Apps (macOS 26; Präfixe werden über die laufenden Audio-Prozesse aufgelöst);
    /// nil = alles außer Transcriber selbst. muted: Ton der abgegriffenen Prozesse nicht ausgeben (nur für Tests).
    func start(bundleIDs: [String]? = nil, muted: Bool = false,
               onBuffer: @escaping (AVAudioPCMBuffer, UInt64) -> Void) throws {
        let desc: CATapDescription
        if let ids = bundleIDs, #available(macOS 26, *) {
            desc = CATapDescription(__monoMixdownOfProcesses: [])
            desc.bundleIDs = Self.expand(ids)
            desc.isProcessRestoreEnabled = true
        } else {
            let own = Self.ownProcessObject().map { [NSNumber(value: $0)] } ?? []
            desc = CATapDescription(__monoGlobalTapButExcludeProcesses: own)
        }
        desc.uuid = UUID()
        desc.name = "Transcriber"
        desc.isPrivate = true
        desc.muteBehavior = muted ? .muted : .unmuted
        try check(AudioHardwareCreateProcessTap(desc, &tapID), "Tap anlegen (Freigabe „Systemaudio“?)")

        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var a = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal,
                                           mElement: kAudioObjectPropertyElementMain)
        try check(AudioObjectGetPropertyData(tapID, &a, 0, nil, &size, &asbd), "Tap-Format lesen")
        guard let fmt = AVAudioFormat(streamDescription: &asbd) else { throw Failure(msg: "Tap-Format unbrauchbar") }
        format = fmt

        let agg: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Transcriber Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: desc.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]],
        ]
        try check(AudioHardwareCreateAggregateDevice(agg as CFDictionary, &aggID), "Aggregatgerät anlegen")
        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, queue) { _, input, inTime, _, _ in
            guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, bufferListNoCopy: input, deallocator: nil) else { return }
            onBuffer(buf, inTime.pointee.mHostTime)
        }, "IOProc anlegen")
        try check(AudioDeviceStart(aggID, procID), "Abgriff starten")
    }

    func stop() {
        if aggID != kAudioObjectUnknown {
            if let p = procID { AudioDeviceStop(aggID, p); AudioDeviceDestroyIOProcID(aggID, p) }
            AudioHardwareDestroyAggregateDevice(aggID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil; aggID = AudioObjectID(kAudioObjectUnknown); tapID = AudioObjectID(kAudioObjectUnknown)
    }

    deinit { stop() }

    private func check(_ st: OSStatus, _ what: String) throws {
        guard st == noErr else { stop(); throw Failure(msg: "\(what) fehlgeschlagen (\(st))") }
    }

    /// Präfixe (z. B. „com.google.Chrome“) → alle passenden Bundle-IDs laufender Audio-Prozesse (Hilfsprozesse der
    /// Browser haben eigene IDs) plus die Präfixe selbst.
    static func expand(_ prefixes: [String]) -> [String] {
        let running = CallDetector.processObjects().compactMap(CallDetector.bundleID)
        return Array(Set(prefixes + running.filter { b in prefixes.contains { b.hasPrefix($0) } }))
    }

    static func ownProcessObject() -> AudioObjectID? {
        var pid = getpid()
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                           mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var obj = AudioObjectID(kAudioObjectUnknown); var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let st = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &obj)
        return st == noErr && obj != kAudioObjectUnknown ? obj : nil
    }
}
