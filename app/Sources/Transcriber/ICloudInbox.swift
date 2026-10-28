import AppKit
import CoreImage.CIFilterBuiltins

/// iPhone-Weg: Eingangsordner „iCloud Drive › Transcriber“ (und „› Kurzbefehle › Transcriber“, s. u.). Aufnahmen, die dort ankommen (Kurzbefehl „An Transcriber
/// senden“, Dateien-App), holt die App nach `~/Transcriber/iPhone` – ab da transkribiert der Wächter wie bei `Handy`.
/// Verschoben, nicht kopiert: Die Aufnahme liegt nur kurz in iCloud und verschwindet danach auch am iPhone. Transkripte
/// und Arbeitsdateien (.lock …) kommen nie in iCloud.
/// Ausgelagerte Dateien („Mac-Speicher optimieren“) haben Größe, aber keinen Inhalt (`SF_DATALESS`): erst herunterladen,
/// sonst blockiert das Verschieben, bis iCloud liefert. Gemessen 2026-10-24: `rename` einer solchen Datei lädt sie selbst
/// nach – der Download vorab hält nur den Takt frei, wenn das Netz fehlt.
enum ICloudInbox {
    static var enabled: Bool { UserDefaults.standard.bool(forKey: "icloudInbox") }
    static let drive = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
    static let inbox = drive.appendingPathComponent("Transcriber")
    /// „iCloud Drive › Kurzbefehle › Transcriber“: Dorthin sichert der Kurzbefehl „An Transcriber senden“ – ohne
    /// Ordnerwahl (die wäre gerätegebunden) kann „Datei sichern“ nur in den iCloud-Ordner der Kurzbefehle-App.
    static let shortcutInbox = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Mobile Documents/iCloud~is~workflow~my~workflows/Documents/Transcriber")
    static var inboxes: [URL] { [inbox, shortcutInbox] }
    static let target = watchDir.appendingPathComponent("iPhone")
    /// Wie `watch.EXT` im Kern (samt .qta, mehrspurige Sprachmemos).
    static let ext: Set<String> = ["m4a", "mp3", "wav", "aac", "flac", "ogg", "opus", "mp4", "mov", "m4v", "mkv", "webm",
                                   "caf", "aiff", "aif", "qta"]
    /// iCloud Drive eingeschaltet (der Ordner fehlt ohne Anmeldung bzw. mit ausgeschaltetem iCloud Drive).
    static var available: Bool { FileManager.default.fileExists(atPath: drive.path) }

    static let queue = DispatchQueue(label: "icloud-inbox")           // Verschieben kann warten (Download) – nie im Hauptthread
    private static var seen: [String: [Int]] = [:]                       // Pfad → (Größe, Änderungszeit) vom letzten Takt
    private static var timer: Timer?

    static func start() {
        let t = Timer(timeInterval: 10, repeats: true) { _ in
            if enabled { queue.async { tick() } }
            if AirDropInbox.enabled { queue.async { AirDropInbox.tick() } }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        if enabled { queue.async { tick() } }
        if AirDropInbox.enabled { queue.async { AirDropInbox.tick() } }
    }

    /// Ein Durchgang: Ausgelagertes anstoßen, Ruhiges verschieben. Liefert die verschobenen Ziele (für den Selbsttest).
    @discardableResult
    static func tick() -> [URL] {
        guard available else { return [] }
        let fm = FileManager.default
        try? fm.createDirectory(at: inbox, withIntermediateDirectories: true)   // damit er am iPhone in „Dateien“ erscheint
        let files = inboxes.flatMap {
            (try? fm.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        }
        var moved: [URL] = []
        var now: [String: [Int]] = [:]
        for f in files where ext.contains(f.pathExtension.lowercased()) {
            var st = stat()
            guard lstat(f.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { continue }
            if st.st_flags & UInt32(SF_DATALESS) != 0 {
                do { try fm.startDownloadingUbiquitousItem(at: f) }
                catch { appLog("iCloud-Eingang: Download \(f.lastPathComponent): \(error.localizedDescription)") }
                continue
            }
            let sig = [Int(st.st_size), Int(st.st_mtimespec.tv_sec)]
            now[f.path] = sig
            guard seen[f.path] == sig else { continue }   // erst im nächsten Takt, wenn unverändert
            if let dest = move(f) { moved.append(dest); now.removeValue(forKey: f.path) }
        }
        seen = now
        return moved
    }

    /// Koordiniert verschieben (iCloud erfährt so vom Wegzug), nie überschreiben: „Name 2.m4a“ … – bei
    /// „Aufnahme JJJJ-MM-TT HH-MM 2“ greift der sprechende Name trotzdem (RecordingTitle.defaultStamp).
    /// `named`: neuer Name ohne Endung (AirDrop-Eingang vergibt den Standardnamen).
    static func move(_ src: URL, named: String? = nil, label: String = "iCloud-Eingang") -> URL? {
        let fm = FileManager.default
        try? fm.createDirectory(at: target, withIntermediateDirectories: true)
        let stem = named ?? src.deletingPathExtension().lastPathComponent, e = src.pathExtension
        var dest = target.appendingPathComponent("\(stem).\(e)")
        var n = 2
        while fm.fileExists(atPath: dest.path) || fm.fileExists(atPath: target.appendingPathComponent(dest.deletingPathExtension().lastPathComponent + ".transcript.json").path) {
            dest = target.appendingPathComponent("\(stem) \(n).\(e)"); n += 1
        }
        var err: NSError?, failure: Error?
        NSFileCoordinator().coordinate(writingItemAt: src, options: .forMoving, writingItemAt: dest, options: .forReplacing, error: &err) { s, d in
            do { try fm.moveItem(at: s, to: d) } catch { failure = error }
        }
        if let e = err ?? failure {
            appLog("\(label): \(src.lastPathComponent) nicht verschoben: \(e.localizedDescription)")
            return nil
        }
        appLog("\(label): \(src.lastPathComponent) → iPhone/\(dest.lastPathComponent)")
        return dest
    }

    // MARK: Kurzbefehl „An Transcriber senden“ aufs iPhone bringen (Einstellungen: QR-Code, AirDrop)

    /// Name = Dateiname = Name des Kurzbefehls nach dem Import (erzeugt von `shortcut/build.py`).
    static var shortcutName: String {
        Locale.preferredLanguages.first?.hasPrefix("de") == true ? "An Transcriber senden" : "Send to Transcriber"
    }
    static var shortcutFile: URL? {
        Bundle.main.url(forResource: shortcutName, withExtension: "shortcut", subdirectory: "shortcut")
    }
    /// Dieselbe Datei auf der Website (website/assets/shortcut/) – Ziel des QR-Codes.
    static var shortcutWebURL: URL {
        URL(string: "https://transcriber.teconomix.net/assets/shortcut/"
            + (shortcutName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "") + ".shortcut")!
    }

    /// QR-Code (Core Image, ohne zusätzliches Paket), scharf hochskaliert.
    static func qrCode(_ url: URL, size: CGFloat = 132) -> NSImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(url.absoluteString.utf8)
        f.correctionLevel = "M"
        guard let out = f.outputImage else { return nil }
        let scaled = out.transformed(by: CGAffineTransform(scaleX: size * 2 / out.extent.width, y: size * 2 / out.extent.height))
        guard let cg = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: size, height: size))
    }

    static func sendShortcutViaAirDrop() {
        guard let file = shortcutFile, let s = NSSharingService(named: .sendViaAirDrop), s.canPerform(withItems: [file]) else {
            appLog("Kurzbefehl: AirDrop nicht verfügbar (\(shortcutFile?.path ?? "Datei fehlt im App-Bundle"))")
            NSWorkspace.shared.activateFileViewerSelecting(shortcutFile.map { [$0] } ?? [])
            return
        }
        s.perform(withItems: [file])
    }

    /// Selbsttest `--icloud-test [SEKUNDEN]`: Eingang abholen (auch wenn die Einstellung aus ist), bis er leer ist oder die
    /// Zeit um ist (Standard 120 s); Ergebnis nach stdout und app.log.
    static func selfTest(seconds: Double) {
        let end = Date().addingTimeInterval(seconds)
        print("iCloud Drive: \(available ? "an" : "AUS"), Eingang " + inboxes.map(\.path).joined(separator: ", "))
        var all: [URL] = []
        while Date() < end {
            all += queue.sync { tick() }
            let left = inboxes.flatMap {
                (try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            }.filter { ext.contains($0.pathExtension.lowercased()) }
            if left.isEmpty { break }
            print("wartet: " + left.map(\.lastPathComponent).joined(separator: ", "))
            Thread.sleep(forTimeInterval: 5)
        }
        print("verschoben: \(all.count)"); all.forEach { print("  \($0.path)") }
    }
}
