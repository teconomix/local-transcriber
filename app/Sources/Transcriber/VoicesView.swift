import SwiftUI

/// Fenster „Stimmen“: bekannte Personen mit ihren Stimmreferenzen; einzelne Referenzen oder ganze Personen entfernen.
/// Daten kommen aus `transcriber speakers check --json` (Ähnlichkeit jeder Referenz zum Mittel der übrigen).
struct VoiceRef: Identifiable {
    let id: Int
    let file: String
    let label: String
    let minutes: Double
    let origin: String
    let created: Date?
    let simToRest: Double?
    var suspicious: Bool { (simToRest ?? 1) < 0.6 }
}

@MainActor
final class VoicesModel: ObservableObject {
    @Published var persons: [(name: String, refs: [VoiceRef])] = []
    @Published var error: String?
    @Published var loading = false

    func load() async {
        loading = true; defer { loading = false }
        let (ok, out) = await Core.run(["speakers", "check", "--json"])
        guard ok, let line = out.split(separator: "\n").last(where: { $0.hasPrefix("{") }),
              let d = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: [[String: Any]]] else {
            error = ok ? String(localized: "Antwort nicht lesbar") : out; return
        }
        error = nil
        persons = d.keys.sorted().map { name in
            (name, (d[name] ?? []).map { r in
                VoiceRef(id: r["id"] as? Int ?? 0,
                         file: URL(fileURLWithPath: r["source"] as? String ?? "").lastPathComponent,
                         label: r["label"] as? String ?? "",
                         minutes: (r["speech_s"] as? Double ?? 0) / 60,
                         origin: r["origin"] as? String ?? "",
                         created: (r["created"] as? Double).map { Date(timeIntervalSince1970: $0) },
                         simToRest: r["sim_to_rest"] as? Double)
            })
        }
    }

    func drop(_ ref: VoiceRef) async {
        let (ok, out) = await Core.run(["speakers", "drop", String(ref.id)])
        if !ok { error = out }
        await load()
    }

    func forget(_ name: String) async {
        let (ok, out) = await Core.run(["speakers", "forget", name])
        if !ok { error = out }
        await load()
    }
}

struct VoicesView: View {
    @StateObject private var model = VoicesModel()
    @State private var dropRef: VoiceRef?
    @State private var forgetName: String?

    private static let originText = ["enrolled": String(localized: "eingelernt"), "confirmed": String(localized: "bestätigt"), "named": String(localized: "benannt")]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Je Referenz: Ähnlichkeit zu den übrigen Referenzen derselben Person. Orange (< 0,60) = vermutlich falsch zugeordnet.")
                .font(.caption).foregroundStyle(.secondary)
            if let e = model.error { Text(e).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            List {
                ForEach(model.persons, id: \.name) { p in
                    Section {
                        ForEach(p.refs) { r in row(r) }
                    } header: {
                        HStack {
                            Text(p.name).font(.headline)
                            Text("\(p.refs.count) Referenzen · \(String(format: "%.1f", p.refs.map(\.minutes).reduce(0, +))) min")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Person löschen …", role: .destructive) { forgetName = p.name }.controlSize(.small)
                        }
                    }
                }
            }
            HStack {
                Button("Aktualisieren") { Task { await model.load() } }
                if model.loading { ProgressView().controlSize(.small) }
            }
        }
        .padding(12)
        .frame(minWidth: 620, minHeight: 420)
        .task { await model.load() }
        .confirmationDialog("Referenz entfernen?", isPresented: Binding(get: { dropRef != nil }, set: { if !$0 { dropRef = nil } })) {
            Button("Entfernen", role: .destructive) { if let r = dropRef { Task { await model.drop(r) } } }
        } message: {
            Text(dropRef.map { String(localized: "\($0.file) (\($0.label)) wird nicht mehr zur Erkennung genutzt. Transkripte bleiben unverändert.") } ?? "")
        }
        .confirmationDialog("Person löschen?", isPresented: Binding(get: { forgetName != nil }, set: { if !$0 { forgetName = nil } })) {
            Button("\(forgetName ?? "") samt allen Referenzen löschen", role: .destructive) {
                if let n = forgetName { Task { await model.forget(n) } }
            }
        } message: {
            Text("Alle Stimmreferenzen dieser Person werden entfernt. Transkripte bleiben unverändert.")
        }
    }

    private func row(_ r: VoiceRef) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(r.file).lineLimit(1).truncationMode(.middle)
                Text("\(r.label) · \(String(format: "%.1f", r.minutes)) min · \(Self.originText[r.origin] ?? r.origin)"
                     + (r.created.map { " · " + $0.formatted(date: .abbreviated, time: .shortened) } ?? ""))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(r.simToRest.map { String(format: "%.2f", $0) } ?? "–")
                .monospacedDigit().foregroundStyle(r.suspicious ? .orange : .secondary)
                .help("Ähnlichkeit zu den übrigen Referenzen dieser Person")
            Button { dropRef = r } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                .help("Diese Referenz entfernen")
        }
    }
}
