import Foundation

/// Speicherverbrauch der App stündlich ins app.log („Speicher: … MB“). Anlass 2026-11-12: nach zehn Tagen Laufzeit
/// 26 GB, fast alles SwiftUI-Beobachtungsdaten (ObservationTracking) – ohne Protokoll fiel das erst über die
/// Aktivitätsanzeige auf. Gemessen wie `footprint` (phys_footprint), nicht RSS: Ausgelagertes zählt mit.
enum MemoryWatch {
    private static var timer: Timer?

    static func footprintMB() -> Int? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? Int(info.phys_footprint / 1_048_576) : nil
    }

    static func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 3600, repeats: true) { _ in
            if let mb = footprintMB() { appLog("Speicher: \(mb) MB") }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        if let mb = footprintMB() { appLog("Speicher: \(mb) MB (Start)") }
    }
}
