import SwiftUI

/// Einstellungen › KI: Zusammenfassung nach dem Transkribieren (feature/ki-nachbearbeitung).
/// Gespeichert in config.json „ai“ (gilt auch für CLI und MCP), Schlüssel im Schlüsselbund.
struct AISettings: View {
    @EnvironmentObject var jobs: JobManager
    @State private var provider = AI.provider
    @State private var baseURL = AI.settings["base_url"] as? String ?? ""
    @State private var model = AI.model
    @State private var key = ""
    @State private var auto = AI.auto
    @State private var autoTemplate = AI.autoTemplate
    @State private var cloudOnClick = !AI.cloudAuto
    @State private var pseudonymize = AI.settings["pseudonymize"] as? Bool ?? true
    @State private var handoff = AI.handoff
    @State private var startCommand = AI.settings["start_command"] as? String ?? ""
    @State private var idleStop = AI.settings["idle_stop_min"] as? Int ?? 15
    @State private var models: [String] = []
    @State private var testing = false
    @State private var testResult: (ok: Bool, text: String)?
    @State private var editing: SummaryTemplate?

    init(demo: Bool = false) {                    // Bild für Website/Doku (--ui-test --demo): typische lokale Einrichtung
        guard demo else { return }
        _provider = State(initialValue: "ollama"); _model = State(initialValue: "qwen3.5:27b"); _auto = State(initialValue: true)
        _testResult = State(initialValue: (true, String(localized: "erreichbar · \(3) Modell(e)")))
    }

    private var preset: (id: String, title: String, url: String)? { AI.providers.first { $0.id == provider } }
    private var url: String { provider == "custom" ? baseURL : preset?.url ?? "" }
    private var local: Bool { AI.isLocal(url) }

    var body: some View {
        Form {
            Section {
                Toggle("Nach jeder Transkription automatisch zusammenfassen", isOn: $auto)
                    .onChange(of: auto) { _, v in AI.set("auto", v) }
                Picker("Vorlage dafür", selection: $autoTemplate) {
                    ForEach(jobs.templates) { Text($0.name).tag($0.id) }
                }
                .onChange(of: autoTemplate) { _, v in AI.set("auto_template", v) }
            } header: {
                Text("Zusammenfassung")
            } footer: {
                Text("Fasst fertige Transkripte mit einem Sprachmodell zusammen. Das Ergebnis liegt als eigene Datei (.summary.md) neben dem Transkript; das Transkript bleibt unverändert. Ohne Automatik: „Zusammenfassen“ am Eintrag.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Picker("Anbieter", selection: $provider) {
                    ForEach(AI.providers, id: \.id) { Text($0.title).tag($0.id) }
                }
                .onChange(of: provider) { _, v in
                    AI.set("provider", v); AI.set("base_url", v == "custom" ? baseURL : nil)
                    models = []; testResult = nil; key = ""
                }
                if provider == "custom" {
                    TextField("Adresse", text: $baseURL, prompt: Text("http://localhost:8080/v1"))
                        .onSubmit { AI.set("base_url", baseURL) }
                        .onChange(of: baseURL) { _, v in AI.set("base_url", v) }   // auch ohne Return (Reiter gewechselt)
                } else {
                    LabeledContent("Adresse", value: url)
                }
                HStack {
                    TextField("Modell", text: $model, prompt: Text("Name des Modells"))
                        .onSubmit { AI.set("model", model) }
                        .onChange(of: model) { _, v in AI.set("model", v) }
                    if !models.isEmpty {
                        Menu("Auswahl") { ForEach(models, id: \.self) { m in Button(m) { model = m } } }.fixedSize()
                    }
                }
                if local {
                    TextField("Startbefehl", text: $startCommand, prompt: Text("optional, z. B. ollama serve"))
                        .onSubmit { AI.set("start_command", startCommand) }
                        .onChange(of: startCommand) { _, v in AI.set("start_command", v.trimmingCharacters(in: .whitespaces)) }
                    if !startCommand.trimmingCharacters(in: .whitespaces).isEmpty {
                        Picker("Wieder beenden", selection: $idleStop) {
                            ForEach([5, 15, 30, 60], id: \.self) { Text("nach \($0) min ohne Nutzung").tag($0) }
                            Text("nie").tag(0)
                        }
                        .onChange(of: idleStop) { _, v in AI.set("idle_stop_min", v) }
                    }
                }
                if !local {
                    SecureField("Schlüssel", text: $key, prompt: Text(AI.key(provider) == nil ? "API-Schlüssel" : "gespeichert – zum Ändern neu eingeben"))
                        .onSubmit { AI.setKey(key, for: provider); key = "" }
                        // auch ohne Return sichern – sonst war ein eingefügter Schlüssel beim Reiterwechsel still weg
                        .onChange(of: key) { _, v in if !v.isEmpty { AI.setKey(v, for: provider) } }
                }
                HStack {
                    Button("Verbindung testen") { Task { await test() } }.disabled(testing || url.isEmpty)
                    if testing { ProgressView().controlSize(.small) }
                    if let r = testResult {
                        Label(r.text, systemImage: r.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(r.ok ? .green : .orange).font(.caption).lineLimit(2)
                    }
                }
            } header: {
                Text("Modell")
            } footer: {
                Text(local
                     ? "Lokal: Das Gespräch verlässt den Mac nicht. Ollama und LM Studio sind verbreitet, MTPLX ist auf Apple Silicon deutlich schneller. Jeder Server mit Schnittstelle nach OpenAI-Art geht über „Eigene Adresse“. Mit Startbefehl startet Transcriber den Server, wenn er nicht läuft, und beendet ihn nach der eingestellten Zeit ohne Nutzung bzw. beim Beenden der App wieder – einen selbst gestarteten Server lässt es in Ruhe."
                     : "Cloud: Das Transkript wird an diesen Anbieter geschickt. Der Schlüssel liegt im Schlüsselbund, nicht in Dateien.")
                    .font(.caption).foregroundStyle(local ? Color.secondary : Color.orange)
            }

            Section("Datenschutz") {
                Toggle("Cloud-Modelle nur auf Klick, nie automatisch", isOn: $cloudOnClick)
                    .onChange(of: cloudOnClick) { _, v in AI.set("cloud_auto", !v) }
                Toggle("Namen vor dem Senden in die Cloud durch Platzhalter ersetzen", isOn: $pseudonymize)
                    .onChange(of: pseudonymize) { _, v in AI.set("pseudonymize", v) }
                Toggle("„Weiterarbeiten in Claude / Codex“ anbieten", isOn: $handoff)
                    .onChange(of: handoff) { _, v in AI.set("handoff", v) }
            }

            Section {
                ForEach(jobs.templates) { t in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 4) {
                                if t.id == autoTemplate { Image(systemName: "star.fill").foregroundStyle(.yellow).font(.caption2) }
                                Text(t.name)
                                if t.custom { Text(t.builtin ? "geändert" : "eigene").font(.caption2).foregroundStyle(.secondary) }
                            }
                            Text(t.description).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Button("Bearbeiten") { editing = t }.buttonStyle(.link)
                    }
                }
                HStack {
                    Button("Neue Vorlage") { editing = newTemplate() }.buttonStyle(.link)
                    Text("·").foregroundStyle(.tertiary)
                    Button("Vorlagenordner zeigen") {
                        let d = Core.data.appendingPathComponent("prompts")
                        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(d)
                    }.buttonStyle(.link)
                }
                .font(.caption)
            } header: {
                Text("Vorlagen")
            } footer: {
                Text("Dieselben Vorlagen bietet der MCP-Server an, z. B. in Claude Desktop als /protokoll.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { if jobs.templates.isEmpty { await jobs.loadTemplates() } }
        .sheet(item: $editing) { t in
            TemplateEditor(template: t) { editing = nil; Task { await jobs.loadTemplates() } }
        }
    }

    private func test() async {
        AI.set("model", model)
        if provider == "custom" { AI.set("base_url", baseURL) }
        if !key.isEmpty { AI.setKey(key, for: provider); key = "" }
        testing = true; testResult = nil
        let (ok, out) = await Core.run(["summarize", "--models", "--json"], env: AI.env)
        testing = false
        guard ok, let line = out.split(separator: "\n").last, let d = line.data(using: .utf8),
              let r = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
            testResult = (false, out.split(separator: "\n").last.map { String($0).replacingOccurrences(of: "Fehler: ", with: "") }
                          ?? String(localized: "nicht erreichbar"))
            return
        }
        models = r["models"] as? [String] ?? []
        if model.isEmpty, let first = models.first { model = first }
        let known = models.isEmpty || models.contains(model)
        testResult = (known, known ? String(localized: "erreichbar · \(models.count) Modell(e)")
                                   : String(localized: "erreichbar, aber Modell „\(model)“ unbekannt"))
    }

    private func newTemplate() -> SummaryTemplate {
        let d = Core.data.appendingPathComponent("prompts")
        var n = 1
        while FileManager.default.fileExists(atPath: d.appendingPathComponent("eigene-\(n).md").path) { n += 1 }
        return SummaryTemplate(id: "eigene-\(n)", name: String(localized: "Eigene Vorlage \(n)"), description: "", custom: true,
                               builtin: false, path: d.appendingPathComponent("eigene-\(n).md").path)
    }
}

/// Vorlage als Text bearbeiten: Name, Beschreibung, Prompt. Gesichert wird immer unter DATA/prompts/<id>.md –
/// eine mitgelieferte Vorlage bleibt unberührt, „Zurücksetzen“ löscht nur die eigene Fassung.
struct TemplateEditor: View {
    let template: SummaryTemplate
    let done: () -> Void
    @State private var name = ""
    @State private var desc = ""
    @State private var body_ = ""
    @State private var confirmDelete = false

    private var target: URL { Core.data.appendingPathComponent("prompts/\(template.id).md") }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(template.builtin && !template.custom ? "Mitgelieferte Vorlage – gesichert wird eine eigene Fassung." : "Eigene Vorlage")
                .font(.caption).foregroundStyle(.secondary)
            Form {
                TextField("Name", text: $name)
                TextField("Beschreibung", text: $desc)
            }
            TextEditor(text: $body_)
                .font(.system(.caption, design: .monospaced))
                .frame(minHeight: 260)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.quaternary))
            Text("Platzhalter: {{title}} {{date}} {{participants}} {{event}} {{language}} {{transcript}}")
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            HStack {
                if template.custom {
                    Button(template.builtin ? "Zurücksetzen" : "Löschen", role: .destructive) { confirmDelete = true }
                        .confirmationDialog(template.builtin ? "Eigene Fassung verwerfen?" : "Vorlage löschen?", isPresented: $confirmDelete) {
                            Button(template.builtin ? "Zurücksetzen" : "Löschen", role: .destructive) {
                                try? FileManager.default.trashItem(at: target, resultingItemURL: nil); done()   // Papierkorb
                            }
                        }
                }
                Spacer()
                Button("Abbrechen") { done() }.keyboardShortcut(.cancelAction)
                Button("Sichern") { save(); done() }.keyboardShortcut(.defaultAction).disabled(name.isEmpty || body_.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 560, height: 520)
        .onAppear(perform: load)
    }

    private func load() {
        name = template.name; desc = template.description
        guard let text = try? String(contentsOfFile: template.path, encoding: .utf8) else {
            body_ = "{{transcript}}\n"; return
        }
        // Kopf (--- name/description ---) wie summarize._parse abtrennen
        if text.hasPrefix("---\n"), let end = text.range(of: "\n---\n") {
            body_ = String(text[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        } else { body_ = text }
    }

    private func save() {
        let clean = { (s: String) in s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces) }
        let text = "---\nname: \(clean(name))\ndescription: \(clean(desc))\n---\n" + body_.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        do {
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: target, atomically: true, encoding: .utf8)
        } catch { appLog("Vorlage nicht gesichert: \(error.localizedDescription)") }
    }
}
