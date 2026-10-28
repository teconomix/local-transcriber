import SwiftUI

/// Ein Transkript unter ~/Transcriber (`transcriber library --json`).
struct LibraryEntry: Decodable, Identifiable, Equatable {
    let transcript: String
    let readable: String?
    let title: String
    let folder: String
    let source: String
    let audio: Bool
    let audio_bytes: Int64
    let recorded: String?
    let recorded_from: String
    let activity_ts: Double
    let duration: Double
    let event: String?
    let speakers: [String]
    let open: Int
    let summary: String?
    var id: String { transcript }
}

@MainActor
final class LibraryModel: ObservableObject {
    enum Sort: String, CaseIterable { case recorded, activity, title, length }
    @Published var items: [LibraryEntry] = []
    @Published var loading = false
    @Published var error: String?
    private var rows: [String: Job] = [:]           // Detail: dieselbe Ansicht wie im Panel

    func load() async {
        loading = true
        defer { loading = false }
        let (ok, out) = await Core.run(["library", "--json"])
        guard ok, let line = out.split(separator: "\n").last, let d = line.data(using: .utf8),
              let list = try? JSONDecoder().decode([LibraryEntry].self, from: d) else {
            appLog("Alle Transkriptionen nicht gelesen: \(out.suffix(300))")
            error = String(localized: "Liste konnte nicht gelesen werden"); return
        }
        error = nil
        if list != items { items = list }
        rows = rows.filter { k, _ in list.contains { $0.transcript == k } }
    }

    func job(for e: LibraryEntry) -> Job {
        if let j = rows[e.transcript] { return j }
        let j = Job(id: "library:" + e.transcript, source: URL(fileURLWithPath: e.source), started: Date(timeIntervalSince1970: e.activity_ts))
        j.state = .done
        j.audioGone = !e.audio
        j.jsonURL = URL(fileURLWithPath: e.transcript)
        j.mdURL = e.readable.map { URL(fileURLWithPath: $0) }
        j.loadSpeakers()
        rows[e.transcript] = j
        return j
    }
}

/// Fenster „Alle Transkriptionen“: alles unter ~/Transcriber, nichts ausgeblendet. Links die Liste (Ordner, Sortierung,
/// Suche), rechts der gewählte Eintrag wie im Panel – benennen, zusammenfassen, löschen.
struct LibraryView: View {
    @EnvironmentObject var jobs: JobManager
    @StateObject private var model = LibraryModel()
    @AppStorage("librarySort") private var sort = LibraryModel.Sort.recorded.rawValue
    @AppStorage("libraryFolder") private var folder = "*"
    @State private var query = ""
    @State private var selection: String?

    private var folders: [String] { Array(Set(model.items.map(\.folder))).sorted { $0.localizedStandardCompare($1) == .orderedAscending } }

    private var shown: [LibraryEntry] {
        // Mehrere Begriffe: alle müssen vorkommen – „Anna Max“ = Gespräche, in denen beide dabei waren
        let terms = query.lowercased().split(whereSeparator: { $0.isWhitespace || $0 == "," }).map(String.init)
        let list = model.items.filter { e in
            guard folder == "*" || e.folder == folder else { return false }
            let text = ([e.title, e.event ?? ""] + e.speakers).joined(separator: " ").lowercased()
            return terms.allSatisfy { text.contains($0) }
        }
        switch LibraryModel.Sort(rawValue: sort) ?? .recorded {
        case .recorded: return list.sorted { ($0.recorded ?? "") > ($1.recorded ?? "") }
        case .activity: return list.sorted { $0.activity_ts > $1.activity_ts }
        case .title: return list.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .length: return list.sorted { $0.duration > $1.duration }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            toolbar
            HStack(alignment: .top, spacing: 0) {
                list.frame(width: 400)
                Divider().padding(.horizontal, 10)
                ScrollView { detail }.frame(width: 412)
            }
            .frame(maxHeight: .infinity)
            footer
        }
        .padding(16)
        .frame(minWidth: 860, minHeight: 420)
        .task { await model.load() }
        .onChange(of: jobs.changes) { _, _ in Task { await model.load() } }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in Task { await model.load() } }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            // Ab vier Unterordnern ein Auswahlmenü statt Knöpfen – sonst wird die Leiste zu breit
            if folders.count > 3 {
                folderPicker.pickerStyle(.menu).fixedSize()
            } else {
                folderPicker.pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            Picker("Sortieren", selection: $sort) {
                Text("Aufnahmedatum").tag(LibraryModel.Sort.recorded.rawValue)
                Text("Zuletzt bearbeitet").tag(LibraryModel.Sort.activity.rawValue)
                Text("Titel").tag(LibraryModel.Sort.title.rawValue)
                Text("Länge").tag(LibraryModel.Sort.length.rawValue)
            }
            .fixedSize()
            Spacer()
            if model.loading { ProgressView().controlSize(.small) }
            TextField("Titel und Namen suchen", text: $query).textFieldStyle(.roundedBorder).frame(width: 200)
                .help("Mehrere Begriffe: Gespräche, in denen alle vorkommen – z. B. „Anna Max“")
        }
    }

    private var folderPicker: some View {
        Picker("Ordner", selection: $folder) {
            Text("Alle").tag("*")
            ForEach(folders, id: \.self) { f in Text(f.isEmpty ? "~/" + watchDir.lastPathComponent : f).tag(f) }
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(shown) { e in
                    row(e)
                        .contentShape(Rectangle())
                        .onTapGesture { selection = e.transcript }
                }
            }
        }
    }

    private func row(_ e: LibraryEntry) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(e.title).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                if e.open > 0 { Text("\(e.open) offen").font(.caption2).foregroundStyle(.orange).help("Sprecher noch nicht bestätigt") }
            }
            HStack(spacing: 6) {
                Text(Self.date(e.recorded))
                    .help(e.recorded_from == "transcript" ? String(localized: "Aufnahmedatum unbekannt – Datum der Transkription") : "")
                    .foregroundStyle(e.recorded_from == "transcript" ? .tertiary : .secondary)
                Text("·").foregroundStyle(.tertiary)
                Text("\(max(1, Int((e.duration / 60).rounded()))) min")
                if !e.folder.isEmpty { Text("·").foregroundStyle(.tertiary); Text(e.folder) }
                if let s = e.summary { Text("·").foregroundStyle(.tertiary); Image(systemName: "text.alignleft"); Text(s) }
                if !e.audio { Text("·").foregroundStyle(.tertiary); Text("ohne Aufnahme") }
            }
            .font(.caption).foregroundStyle(.secondary)
            if !e.speakers.isEmpty {
                Text(e.speakers.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 6).fill(selection == e.transcript ? Color.accentColor.opacity(0.25) : .clear))
    }

    @ViewBuilder private var detail: some View {
        VStack(alignment: .leading) {
            if let e = shown.first(where: { $0.transcript == selection }) ?? shown.first {
                JobRow(job: model.job(for: e), archive: true).id(e.transcript)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let err = model.error {
                Text(err).foregroundStyle(.red)
            } else if !model.loading {
                Text(model.items.isEmpty ? "Noch keine Transkripte im Ordner." : "Nichts gefunden.").foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private var footer: some View {
        let withAudio = model.items.filter(\.audio)
        let bytes = ByteCountFormatter.string(fromByteCount: withAudio.reduce(0) { $0 + $1.audio_bytes }, countStyle: .file)
        return Text("\(model.items.count) Transkripte · \(withAudio.count) mit Aufnahme (\(bytes)) · in ~/\(watchDir.lastPathComponent)")
            .font(.caption).foregroundStyle(.secondary)
    }

    /// „2026-10-24 09:30“ → „24.10.2026 09:30“ (bzw. englisches Format)
    static func date(_ s: String?) -> String {
        guard let s else { return "?" }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"; f.locale = Locale(identifier: "en_US_POSIX")
        guard let d = f.date(from: s) else { return s }
        return d.formatted(date: .numeric, time: .shortened)
    }
}
