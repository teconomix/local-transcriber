import AppKit
import Foundation
import Security

/// KI-Nachbearbeitung (feature/ki-nachbearbeitung): Zusammenfassung fertiger Transkripte über `transcriber summarize`.
/// Einstellungen stehen in config.json unter „ai“ (auch CLI und MCP lesen sie), Schlüssel für Cloud-Anbieter nur im
/// Schlüsselbund – die App reicht ihn als TRANSCRIBER_AI_KEY an den Kernprozess weiter.
enum AI {
    /// Anbieter wie transcriber/summarize.py PROVIDERS. Lokal zuerst; MTPLX ist am schnellsten, Ollama/LM Studio verbreiteter.
    static let providers: [(id: String, title: String, url: String)] = [
        ("ollama", String(localized: "Lokal · Ollama"), "http://localhost:11434/v1"),
        ("lmstudio", String(localized: "Lokal · LM Studio"), "http://localhost:1234/v1"),
        ("mtplx", String(localized: "Lokal · MTPLX"), "http://127.0.0.1:18085/v1"),
        ("openai", String(localized: "Cloud · OpenAI"), "https://api.openai.com/v1"),
        ("anthropic", String(localized: "Cloud · Anthropic"), "https://api.anthropic.com/v1"),
        ("mistral", String(localized: "Cloud · Mistral"), "https://api.mistral.ai/v1"),
        ("openrouter", String(localized: "Cloud · OpenRouter"), "https://openrouter.ai/api/v1"),
        ("custom", String(localized: "Eigene Adresse"), ""),
    ]

    static var settings: [String: Any] { Core.configJSON()["ai"] as? [String: Any] ?? [:] }

    static func set(_ key: String, _ value: Any?) {
        var ai = settings
        ai[key] = value
        Core.setConfig("ai", ai)
    }

    static var provider: String { settings["provider"] as? String ?? "ollama" }
    static var baseURL: String {
        if let u = settings["base_url"] as? String, !u.isEmpty { return u }
        return providers.first { $0.id == provider }?.url ?? ""
    }
    static var model: String { settings["model"] as? String ?? "" }
    static var auto: Bool { settings["auto"] as? Bool ?? false }
    static var autoTemplate: String { settings["auto_template"] as? String ?? "protokoll" }
    static var cloudAuto: Bool { settings["cloud_auto"] as? Bool ?? false }
    static var handoff: Bool { settings["handoff"] as? Bool ?? true }
    static var configured: Bool { !model.isEmpty }

    static func isLocal(_ url: String = baseURL) -> Bool {
        ["127.0.0.1", "localhost", "::1"].contains(URL(string: url)?.host() ?? "")
    }

    // MARK: Schlüsselbund (Dienst „Transcriber KI“, Konto = Anbieter – wie summarize.KEYCHAIN_SERVICE)

    private static let service = "Transcriber KI"

    static func key(_ provider: String = provider) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: provider, kSecReturnData as String: true]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func setKey(_ value: String, for provider: String = provider) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: provider]
        SecItemDelete(q as CFDictionary)
        guard !value.isEmpty else { return }
        var add = q
        add[kSecValueData as String] = Data(value.utf8)
        let r = SecItemAdd(add as CFDictionary, nil)
        if r != errSecSuccess { appLog("Schlüsselbund: Schlüssel nicht gespeichert (\(r))") }
    }

    /// Umgebung für den Kernprozess: Schlüssel nur, wenn der Anbieter nicht lokal ist.
    static var env: [String: String] {
        guard !isLocal(), let k = key() else { return [:] }
        return ["TRANSCRIBER_AI_KEY": k]
    }

    // MARK: Weitergabe an Claude / Codex (Links öffnen die App mit vorbereitetem Text – abgeschickt wird nichts)

    enum Target: CaseIterable { case claude, claudeCode, codex }

    static func installed(_ t: Target) -> Bool {
        let scheme = t == .codex ? "codex://" : "claude://"
        return URL(string: scheme).flatMap { NSWorkspace.shared.urlForApplication(toOpen: $0) } != nil
    }

    static func title(_ t: Target) -> String {
        switch t {
        case .claude: String(localized: "Claude")
        case .claudeCode: String(localized: "Claude Code (im Ordner)")
        case .codex: String(localized: "Codex (im Ordner)")
        }
    }

    /// claude://claude.ai/new?q= (≈ 14 000 Zeichen) · claude://code/new?q=&folder= · codex://new?prompt=&path=
    /// (Doku: support.claude.com 14729294, learn.chatgpt.com/docs/reference/commands). Claude bekommt die
    /// Zusammenfassung als Text; die Varianten mit Ordner nennen nur die Dateien – dort liest das Werkzeug selbst.
    static func handoff(_ t: Target, title: String, summary: URL, transcript: URL?) {
        let folder = summary.deletingLastPathComponent()
        let files = [summary.lastPathComponent] + (transcript.map { [$0.lastPathComponent] } ?? [])
        var c = URLComponents()
        switch t {
        case .claude:
            let body = (try? String(contentsOf: summary, encoding: .utf8))?.split(separator: "\n", maxSplits: 1).last.map(String.init) ?? ""
            let text = String(localized: "Zusammenfassung des Gesprächs „\(title)“ (vollständiges Transkript über den Transcriber-MCP: read_transcript):")
                + "\n\n" + body
            c.scheme = "claude"; c.host = "claude.ai"; c.path = "/new"
            c.queryItems = [URLQueryItem(name: "q", value: String(text.prefix(13_500)))]
        case .claudeCode, .codex:
            let text = String(localized: "Im Ordner liegen Zusammenfassung und Transkript des Gesprächs „\(title)“: \(files.joined(separator: ", ")).") + " "
            if t == .codex {
                c.scheme = "codex"; c.host = "new"
                c.queryItems = [URLQueryItem(name: "prompt", value: text), URLQueryItem(name: "path", value: folder.path)]
            } else {
                c.scheme = "claude"; c.host = "code"; c.path = "/new"
                c.queryItems = [URLQueryItem(name: "q", value: text), URLQueryItem(name: "folder", value: folder.path)]
            }
        }
        // URLComponents lässt „+“, „&“, „=“ in Werten teils stehen – für q/prompt streng kodieren. Nur ASCII erlauben:
        // .alphanumerics enthält auch „ä“, und unkodierte Umlaute lässt percentEncodedQueryItems abstürzen.
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        c.percentEncodedQueryItems = c.queryItems?.map {
            URLQueryItem(name: $0.name, value: $0.value?.addingPercentEncoding(withAllowedCharacters: unreserved))
        }
        if let u = c.url { NSWorkspace.shared.open(u) } else { appLog("Weitergabe: Link nicht gebaut (\(t))") }
    }
}

struct SummaryTemplate: Identifiable, Hashable {
    let id: String
    let name: String
    let description: String
    let custom: Bool
    let builtin: Bool
    let path: String
}

/// Zusammenfassung neben dem Transkript (<name>.summary.md): Kennzeichenzeile mit Angaben (JSON), dann Markdown.
struct SummaryInfo: Equatable {
    let url: URL
    let name: String
    let local: Bool
    let model: String
    let points: [String]
    let tasks: [String]

    static func url(for json: URL) -> URL {
        json.deletingLastPathComponent().appendingPathComponent(
            json.lastPathComponent.replacingOccurrences(of: ".transcript.json", with: "") + ".summary.md")
    }

    static func load(json: URL?) -> SummaryInfo? {
        guard let json else { return nil }
        let u = url(for: json)
        guard let text = try? String(contentsOf: u, encoding: .utf8) else { return nil }
        let lines = text.components(separatedBy: "\n")
        let mark = "<!-- transcriber-summary "
        guard let first = lines.first, first.hasPrefix(mark),
              let end = first.range(of: "-->", options: .backwards),
              let d = String(first[first.index(first.startIndex, offsetBy: mark.count)..<end.lowerBound]).data(using: .utf8),
              let meta = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        // wie summarize.preview: oberste Aufzählungsebene, „- [ ]“ = Aufgabe
        let items = lines.dropFirst().filter { $0.hasPrefix("- ") || $0.hasPrefix("* ") }.map { String($0.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
        let tasks = items.filter { $0.hasPrefix("[ ]") }.map { String($0.dropFirst(3)).trimmingCharacters(in: .whitespaces) }
        let points = items.filter { !$0.hasPrefix("[") }
        return SummaryInfo(url: u, name: meta["name"] as? String ?? "", local: meta["local"] as? Bool ?? true,
                           model: meta["model"] as? String ?? "", points: Array(points.prefix(2)), tasks: Array(tasks.prefix(2)))
    }
}

/// Teilen über das macOS-Menü (Mail, Nachrichten, Notizen, AirDrop …). Als Text: formatiert statt Markdown-Zeichen
/// (Mail bekommt Überschriften fett, Aufgaben als ☐), Betreff vorbelegt. Als Datei: die .summary.md als Anhang.
final class SummaryShare: NSObject, NSSharingServicePickerDelegate {
    private static var current: SummaryShare?      // hält den Delegaten, solange das Menü offen ist
    private let subject: String

    private init(subject: String) { self.subject = subject }

    static func show(_ sum: SummaryInfo, title: String, asFile: Bool) {
        let items: [Any] = asFile ? [sum.url] : [formatted(sum)]
        let picker = NSSharingServicePicker(items: items)
        let share = SummaryShare(subject: sum.name.isEmpty ? title : "\(sum.name): \(title)")
        current = share
        picker.delegate = share
        // Am Mauszeiger im Fenster des Panels aufklappen (SwiftUI liefert hier keine NSView)
        guard let view = NSApp.keyWindow?.contentView ?? NSApp.windows.first(where: \.isVisible)?.contentView,
              let window = view.window else { return }
        let p = view.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        picker.show(relativeTo: NSRect(x: p.x - 1, y: p.y - 1, width: 2, height: 2), of: view, preferredEdge: .minY)
    }

    func sharingServicePicker(_ picker: NSSharingServicePicker, didChoose service: NSSharingService?) {
        service?.subject = subject                    // Mail: Betreff vorbelegt
        if service == nil { Self.current = nil }
    }

    /// Markdown der Zusammenfassung → formatierter Text: ##-Überschriften fett, „- [ ]“ → ☐, „- “ → •, **fett** bleibt fett.
    static func formatted(_ sum: SummaryInfo) -> NSAttributedString {
        let text = (try? String(contentsOf: sum.url, encoding: .utf8))?.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            .dropFirst().first.map(String.init) ?? ""
        let body = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let out = NSMutableAttributedString()
        for raw in text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n") {
            var line = raw, font = body
            if let h = line.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
                line.removeSubrange(h); font = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize + 1)
            }
            let indent = String(line.prefix { $0 == " " })
            let rest = line.dropFirst(indent.count)
            if rest.hasPrefix("- [ ] ") || rest.hasPrefix("* [ ] ") { line = indent + "☐ " + rest.dropFirst(6) }
            else if rest.hasPrefix("- [x] ") || rest.hasPrefix("- [X] ") { line = indent + "☑ " + rest.dropFirst(6) }
            else if rest.hasPrefix("- ") || rest.hasPrefix("* ") { line = indent + "• " + rest.dropFirst(2) }
            let inline = (try? AttributedString(markdown: line, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                .map { NSMutableAttributedString(attributedString: NSAttributedString($0)) } ?? NSMutableAttributedString(string: line)
            let whole = NSRange(location: 0, length: inline.length)
            inline.addAttribute(.font, value: font, range: whole)
            inline.enumerateAttribute(.inlinePresentationIntent, in: whole) { v, r, _ in   // **fett** aus dem Markdown
                if let i = v as? NSNumber, InlinePresentationIntent(rawValue: i.uintValue).contains(.stronglyEmphasized) {
                    inline.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: font.pointSize), range: r)
                }
            }
            out.append(inline)
            out.append(NSAttributedString(string: "\n", attributes: [.font: body]))
        }
        return out
    }
}
