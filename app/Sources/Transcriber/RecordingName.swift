import Foundation

/// Standardname neuer Aufnahmen: „Aufnahme <Datum>“ (en „Recording <Datum>“), Datumsformat einstellbar
/// (Einstellungen › Aufnahme, UserDefaults „nameDateFormat“; Wunsch aus der Nutzung 2026-10-30: „yyMMdd“ statt
/// „yyyy-MM-dd“). Der sprechende Name übernimmt das Datum unverändert („261030 1403 Budgetplanung Q4“).
/// Erkannt werden alle Vorlagen und das eingestellte Format – sonst würden Aufnahmen aus der Zeit vor einem Wechsel
/// (und vom Kurzbefehl, der immer „JJJJ-MM-TT HH-MM“ schreibt) nicht mehr sprechend benannt.
enum RecordingName {
    static let standard = "yyyy-MM-dd HH-mm"
    static let presets = [standard, "yyMMdd HHmm", "yyyyMMdd HHmm"]

    /// Eingestelltes Format; ungültig oder leer → Standard.
    static var format: String { valid(UserDefaults.standard.string(forKey: "nameDateFormat")) ?? standard }

    /// Nur Jahr, Monat, Tag, Stunde, Minute und harmlose Trennzeichen (kein „:“ oder „/“ – in Dateinamen verboten
    /// bzw. ein Ordner); Jahr, Monat und Tag müssen vorkommen, sonst wäre der Name nicht eindeutig.
    static func valid(_ f: String?) -> String? {
        guard let f = f?.trimmingCharacters(in: .whitespaces), !f.isEmpty, f.count <= 24,
              f.allSatisfy({ "yMdHm -_.".contains($0) }),
              f.contains("yy"), f.contains("MM"), f.contains("dd") else { return nil }
        return f
    }

    private static func formatter(_ f: String) -> DateFormatter {
        let d = DateFormatter()
        d.locale = Locale(identifier: "en_US_POSIX"); d.dateFormat = f; d.isLenient = false
        return d
    }

    static func stamp(_ date: Date, format f: String = format) -> String { formatter(f).string(from: date) }

    /// In der Sprache der Oberfläche („Recording …“ bei Englisch).
    static func defaultName(_ date: Date, format f: String = format) -> String { String(localized: "Aufnahme \(stamp(date, format: f))") }

    /// Datum aus einem Stempel in einem der bekannten Formate – nur, wenn er sich genau so zurückschreiben lässt
    /// (sonst ginge z. B. „261030“ als Jahr 2610 durch).
    static func parse(_ s: String) -> (date: Date, format: String)? {
        for f in [format] + presets {
            let d = formatter(f)
            if let date = d.date(from: s), d.string(from: date) == s { return (date, f) }
        }
        return nil
    }

    /// Standardname zerlegt: Präfix, Stempel, Datum, Zusatz („ 2“ bei zwei Aufnahmen derselben Minute) – sonst nil.
    static func split(_ stem: String) -> (prefix: String, stamp: String, date: Date, suffix: String)? {
        for p in ["Aufnahme", "Recording"] where stem.hasPrefix(p + " ") {
            let rest = String(stem.dropFirst(p.count + 1))
            if let r = parse(rest) { return (p, rest, r.date, "") }
            if let m = rest.wholeMatch(of: #/(.+?)([ -]\d+)/#), let r = parse(String(m.1)) {
                return (p, String(m.1), r.date, String(m.2))
            }
        }
        return nil
    }

    /// iCloud/AirDrop: Standardname in einem anderen als dem eingestellten Format (Kurzbefehl) → neuer Name ohne
    /// Endung, sonst nil.
    static func reformatted(_ url: URL, to f: String = format) -> String? {
        guard let s = split(url.deletingPathExtension().lastPathComponent) else { return nil }
        let new = stamp(s.date, format: f)
        return new == s.stamp ? nil : "\(s.prefix) \(new)\(s.suffix)"
    }

    /// Selbsttest `--name-test`: Erkennung und Umformatieren; Ergebnis in app.log, Exit-Code 1 bei Fehlern.
    static func selfTest() -> Bool {
        let cal = Calendar(identifier: .gregorian)
        let date = cal.date(from: DateComponents(year: 2026, month: 10, day: 30, hour: 14, minute: 3))!
        var bad: [String] = []
        func check(_ ok: Bool, _ what: String) { if !ok { bad.append(what) } }
        for f in presets {
            let st = stamp(date, format: f)
            for stem in ["Aufnahme \(st)", "Recording \(st) 2", "Aufnahme \(st)-3"] {
                check(split(stem)?.stamp == st && split(stem)?.date == date, "erkennt \(stem)")
            }
        }
        check(stamp(date, format: "yyMMdd HHmm") == "261030 1403", "yyMMdd HHmm")
        let short = "yyMMdd HHmm"
        check(reformatted(URL(fileURLWithPath: "/x/Aufnahme 2026-10-30 14-03 2.m4a"), to: short) == "Aufnahme 261030 1403 2", "Kurzbefehl → yyMMdd")
        check(reformatted(URL(fileURLWithPath: "/x/Recording 261030 1403.m4a"), to: short) == nil, "schon im Format")
        check(reformatted(URL(fileURLWithPath: "/x/Interview Müller.m4a"), to: short) == nil, "eigener Name bleibt")
        for stem in ["Aufnahme Budget", "2026-10-30 14-03 Budget", "Aufnahme 2026-13-40 14-03", "Aufnahme 261030 1403 Budget"] {
            check(split(stem) == nil, "kein Standardname: \(stem)")
        }
        for f in ["yyyy/MM/dd", "HH:mm", "", "MM-dd", "yyyy-MM-dd EEEE"] { check(valid(f) == nil, "ungültig: \(f)") }
        check(valid(" yyMMdd ") == "yyMMdd", "gültig: yyMMdd")
        appLog(bad.isEmpty ? "Namens-Test bestanden" : "Namens-Test FEHLER: " + bad.joined(separator: "; "))
        return bad.isEmpty
    }
}
