import EventKit
import Foundation

/// Termin zur Aufnahme aus dem macOS-Kalender (EventKit, Systembaustein): Titel → Dateiname, Teilnehmer → Vorschläge
/// beim Benennen und Obergrenze der Sprecherzahl. Liegt als `<Aufnahme>.event.json` neben der Aufnahme
/// (der Python-Kern liest sie; `transcriber rename` nimmt sie mit). Braucht die Freigabe „Kalender – Vollzugriff“.
enum CalendarContext {
    static let store = EKEventStore()
    static var enabled: Bool { UserDefaults.standard.object(forKey: "useCalendar") as? Bool ?? true }
    /// Abgewählte Kalender (calendarIdentifier). Gespeichert wird, was *aus* ist: neue Kalender zählen zunächst mit.
    static var excluded: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "calendarsExcluded") ?? []) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: "calendarsExcluded") }
    }

    /// Alle Ereignis-Kalender, nach Konto gruppiert sortiert (für die Auswahl in den Einstellungen).
    static func calendars() -> [EKCalendar] {
        store.calendars(for: .event).sorted { ($0.source.title, $0.title) < ($1.source.title, $1.title) }
    }

    /// Rang eines Termins: 0 ich bin Teilnehmer/Organisator · 1 ohne Gäste, Kalender beschreibbar (vermutlich meiner)
    /// · 2 ohne Gäste, nur lesbar (geteilt) · 3 Termin anderer mit Gästen, ich nicht dabei. Kleiner ist besser.
    static func rank(_ e: EKEvent) -> Int {
        let people = e.attendees ?? []
        if people.contains(where: \.isCurrentUser) || e.organizer?.isCurrentUser == true { return 0 }
        if people.isEmpty { return e.calendar?.allowsContentModifications == true ? 1 : 2 }
        return 3
    }

    static func access() async -> Bool {
        if EKEventStore.authorizationStatus(for: .event) == .fullAccess { return true }
        return (try? await store.requestFullAccessToEvents()) ?? false
    }

    /// Termin, der jetzt läuft oder in den nächsten 10 min beginnt (nicht ganztägig, nicht abgesagt, nicht aus
    /// abgewählten Kalendern). Bester Rang (siehe rank), dann der mit dem nächstgelegenen Beginn.
    static func current(at now: Date = Date()) -> EKEvent? {
        let off = excluded
        let cals = calendars().filter { !off.contains($0.calendarIdentifier) }
        guard !cals.isEmpty else { return nil }
        let pred = store.predicateForEvents(withStart: now.addingTimeInterval(-12 * 3600), end: now.addingTimeInterval(600), calendars: cals)
        let cands = store.events(matching: pred).filter { e in
            !e.isAllDay && e.startDate <= now.addingTimeInterval(600) && e.endDate >= now.addingTimeInterval(-300)
                && e.attendees?.first(where: \.isCurrentUser)?.participantStatus != .declined
        }
        return cands.min { a, b in
            let ra = rank(a), rb = rank(b)
            return ra != rb ? ra < rb : abs(a.startDate.timeIntervalSince(now)) < abs(b.startDate.timeIntervalSince(now))
        }
    }

    static func info(_ e: EKEvent) -> [String: Any] {
        let iso = ISO8601DateFormatter()
        var people: [[String: Any]] = (e.attendees ?? []).map(person)
        if let o = e.organizer, !people.contains(where: { ($0["email"] as? String) == email(o) }) { people.append(person(o)) }
        return ["title": e.title ?? "", "start": iso.string(from: e.startDate), "end": iso.string(from: e.endDate),
                "calendar": e.calendar?.title ?? "", "attendees": people]
    }

    private static func email(_ p: EKParticipant) -> String {
        p.url.absoluteString.replacingOccurrences(of: "mailto:", with: "")
    }

    private static func person(_ p: EKParticipant) -> [String: Any] {
        let status: String = switch p.participantStatus {
        case .accepted: "zugesagt"
        case .declined: "abgesagt"
        case .tentative: "vielleicht"
        case .pending: "offen"
        default: "unbekannt"
        }
        let mail = email(p)
        let name = p.name.flatMap { $0.contains("@") ? nil : $0 } ?? nameFromEmail(mail)
        return ["name": name, "email": mail, "me": p.isCurrentUser, "status": status]
    }

    /// Google liefert für Gäste oft keinen Anzeigenamen (beobachtet 2026-10-10: nur Adressen). Dann aus der Adresse:
    /// „anna.muster@…“ → „Anna Muster“, „s.beispiel@…“ → „S. Beispiel“, „kim@…“ → „Kim“.
    static func nameFromEmail(_ mail: String) -> String {
        let local = mail.split(separator: "@").first.map(String.init) ?? mail
        let parts = local.split(whereSeparator: { ".-_".contains($0) }).map { p -> String in
            p.count == 1 ? p.uppercased() + "." : p.prefix(1).uppercased() + p.dropFirst()
        }
        return parts.isEmpty ? mail : parts.joined(separator: " ")
    }

    /// Neben die Aufnahme legen: „Aufnahme X.m4a“ → „Aufnahme X.event.json“.
    static func write(_ info: [String: Any], next audio: URL) {
        let url = audio.deletingPathExtension().appendingPathExtension("event.json")
        if let d = try? JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys]) {
            try? d.write(to: url)
        }
    }
}
