import Foundation
import FoundationModels

/// Sprechende Dateinamen für App-Aufnahmen: „Aufnahme 2026-10-10 14-03“ → „2026-10-10 14-03 Budgetplanung Q4“.
/// Titel vom Apple Foundation Model (lokal) aus einem Auszug des fertigen Transkripts; umbenannt wird im Python-Kern
/// (`transcriber rename`), der auch Transkript, Stimmdatenbank und Statusdateien mitzieht.
/// Nur Aufnahmen mit Standardnamen, die fertig werden, während die App läuft – nichts wird nachträglich umbenannt.
enum RecordingTitle {
    static var enabled: Bool { UserDefaults.standard.object(forKey: "autoTitle") as? Bool ?? true }

    /// Datum/Uhrzeit aus dem Standardnamen, sonst nil (Datei wurde schon benannt oder stammt nicht aus der App).
    static func defaultStamp(_ url: URL) -> String? {
        let name = url.deletingPathExtension().lastPathComponent
        guard let m = name.wholeMatch(of: #/Aufnahme (\d{4}-\d{2}-\d{2} \d{2}-\d{2})/#) else { return nil }
        return String(m.1)
    }

    static let instructions = """
    You name audio recordings. Read the German transcript excerpt and output a short German title of 2 to 6 words that \
    names the main topic. If a client or organization is mentioned by name, include that name.
    No date, no quotes, no punctuation at the end. Avoid generic words like Besprechung, Meeting, Gespräch, Aufnahme, \
    Telefonat unless nothing else fits. Output only the title, nothing else.
    """

    /// Auszug: ganzes Transkript, wenn kurz; sonst vier Fenster über die Länge verteilt (Kontext 8192 Tokens).
    static func excerpt(_ json: URL, maxChars: Int = 8000) -> String? {
        guard let d = try? Data(contentsOf: json), let doc = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let words = doc["words"] as? [[String: Any]] else { return nil }
        let text = words.compactMap { $0["w"] as? String }.joined(separator: " ")
        guard text.count > maxChars else { return text.isEmpty ? nil : text }
        let win = maxChars / 4, chars = Array(text)
        return [0.0, 0.3, 0.6, 0.85].map { f -> String in
            let s = min(Int(Double(chars.count) * f), chars.count - win)
            return String(chars[s..<(s + win)])
        }.joined(separator: " … ")
    }

    static func generate(from text: String) async -> String? {
        guard #available(macOS 26, *), DictationCleanup.unavailableReason == nil else { return nil }
        do {
            let model = SystemLanguageModel(useCase: .general, guardrails: .permissiveContentTransformations)
            let r = try await LanguageModelSession(model: model, instructions: instructions)
                .respond(to: text, options: GenerationOptions(sampling: .greedy))
            let t = (r.content.split(separator: "\n").first.map(String.init) ?? "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"„“”»«'*#.:;!? ").union(.whitespaces))
            let words = t.split(separator: " ").count
            guard (3...70).contains(t.count), (1...8).contains(words) else { appLog("Titel verworfen: \(t.count) Zeichen, \(words) Wörter"); return nil }
            return t
        } catch {
            appLog("Titel fehlgeschlagen: \(error)")
            return nil
        }
    }

    /// Titel erzeugen und Aufnahme samt Transkript umbenennen. Liefert die neuen Pfade (source, md, json) oder nil.
    static func apply(source: URL, json: URL) async -> [String: String]? {
        guard enabled, let stamp = defaultStamp(source) else { return nil }
        let t0 = Date()
        // Kalendertermin zuerst (steht fest, kein Raten), sonst Titel vom Apple-Modell aus dem Transkript.
        let ev = source.deletingPathExtension().appendingPathExtension("event.json")
        let calTitle = (try? Data(contentsOf: ev)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["title"] as? String
        var title = calTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if title.isEmpty {
            guard let text = excerpt(json), let t = await generate(from: text) else { return nil }
            title = t
        }
        let (ok, out) = await Core.run(["rename", json.path, "\(stamp) \(title)", "--json"])
        guard ok, let line = out.split(separator: "\n").last, let d = line.data(using: .utf8),
              let paths = try? JSONSerialization.jsonObject(with: d) as? [String: String] else {
            appLog("Umbenennen fehlgeschlagen: \(out)")
            return nil
        }
        appLog(String(format: "Aufnahme benannt in %.1f s: %@", Date().timeIntervalSince(t0), (paths["source"] as NSString?)?.lastPathComponent ?? "?"))
        return paths
    }
}
