import ConfigCore
import SwiftUI

/// Memory: every CLAUDE.md, rule, auto-memory and other-agent file, grouped by project, with guidance and edit/reset/delete.
struct AgentFilesView: View {
    @Environment(AppModel.self) private var model
    @State private var agentFiles: [URL] = []
    @State private var loading = true
    @State private var search = ""
    @State private var editing: URL?
    @State private var bulk = BulkSelection<String>()
    @State private var order = [KeyPathComparator(\MemRow.modified, order: .reverse)]
    @State private var project = "All"
    @State private var level = "All"

    var body: some View {
        let all = Memory.groups(instructions: model.snapshot.instructions, agentFiles: agentFiles, projects: model.snapshot.projects.map(\.path))
        let groups = !search.isEmpty ? all : all.filter { !$0.isEmpty }
        let rows = groups.flatMap { g in g.entries.map { MemRow(entry: $0, project: g.title, name: relativeName($0)) } }
            .filter { project == "All" || $0.project == project }
            .filter { level == "All" || $0.level == level }
            .filter { search.isEmpty || [$0.name, $0.entry.url.path, $0.entry.type.rawValue].contains { $0.localizedCaseInsensitiveContains(search) }
                || $0.entry.recommendations.contains { $0.localizedCaseInsensitiveContains(search) } }
            .sorted(using: order)
        Table(rows, selection: $bulk.ids, sortOrder: $order) {
            TableColumn("Name", value: \MemRow.name) { (r: MemRow) in
                HStack(spacing: 4) {
                    Text(r.name).fontWeight(.medium).foregroundStyle(r.entry.exists ? .primary : .secondary).lineLimit(1).truncationMode(.head)
                    if !r.entry.recommendations.isEmpty { Image(systemName: "lightbulb").foregroundStyle(Ink.warning).help(r.entry.recommendations.joined(separator: "\n")) }
                    if let s = r.entry.stale { Image(systemName: "clock.badge.exclamationmark").foregroundStyle(Ink.warning).help(s) }
                    else if !r.entry.exists { Text("missing").font(.caption).foregroundStyle(.secondary) }
                }
                .scopeRule(scopeInk(r))
                .help(shortPath(r.entry.url))
            }.width(min: 240, ideal: 520)
            TableColumn("Type", value: \MemRow.type) { (r: MemRow) in Text(r.entry.type.rawValue).foregroundStyle(.secondary).lineLimit(1) }.width(min: 90, ideal: 140)
            TableColumn("Scope", value: \MemRow.level) { (r: MemRow) in
                ScopeLabel(current: target(r), fixedLabel: r.level)
            }.width(min: 70, ideal: 100)
            TableColumn("Project", value: \MemRow.project) { (r: MemRow) in Text(r.project).foregroundStyle(.secondary).lineLimit(1) }.width(min: 80, ideal: 140)
            TableColumn("Size", value: \MemRow.size) { (r: MemRow) in
                Text(r.entry.exists ? formatBytes(Int64(r.size)) : "—").monospacedDigit().foregroundStyle(.secondary)
                    .help(r.entry.loaded ? "\(formatTokens(r.entry.tokens)) tokens every session" : "Not loaded into every session")
            }.width(min: 50, ideal: 70)
            TableColumn("Updated", value: \MemRow.modified) { (r: MemRow) in
                Text(r.entry.modified.map { $0.formatted(.relative(presentation: .named)) } ?? "—").foregroundStyle(.secondary).lineLimit(1)
            }.width(min: 80, ideal: 110)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            let picked = rows.filter { ids.contains($0.id) }
            if picked.count == 1, let r = picked.first {
                actions(r.entry)
                if let file = model.snapshot.instructions.first(where: { $0.url == r.entry.url }), let from = ScopeMove.target(of: file) {
                    MoveToMenu(current: from, allowLocal: file.kind != .rule) { t in model.moveScope(r.entry.url.lastPathComponent, to: t) { try ScopeMove.move(instruction: file, to: t) } }
                }
                ForEach(r.entry.actions) { a in Button(a.button) { model.propose(a.title, a.fix) } }
                Divider()
            }
            let urls = picked.map(\.entry).filter(\.exists).map(\.url)
            if !urls.isEmpty {
                Button("Copy Path\(urls.count == 1 ? "" : "s")") { copy(urls.map(\.path).joined(separator: "\n")) }
                if picked.count > 1 { Button("Move \(urls.count) to Trash", role: .destructive) { model.propose("Move \(urls.count) to the Trash", Memory.removal(urls)) } }
            }
        } primaryAction: { ids in
            if let r = rows.first(where: { ids.contains($0.id) }), r.entry.exists { editing = r.entry.url }
        }
        .overlay { if loading && rows.isEmpty { ProgressView("Searching with Spotlight…") } }
        .searchable(text: $search, prompt: "Filter memory")
        .toolbar {
            ToolbarItem {
                Picker("Project", selection: $project) {
                    Text("All projects").tag("All")
                    ForEach(groups.map(\.title), id: \.self) { Text($0).tag($0) }
                }.pickerStyle(.menu).fixedSize()
            }
            ToolbarItem {
                Picker("Level", selection: $level) {
                    ForEach(["All", "User", "Project", "Local", "Auto-memory", "Other agent"], id: \.self) { Text($0 == "All" ? "All levels" : $0).tag($0) }
                }.pickerStyle(.menu).fixedSize()
            }
            ToolbarItem { Button("Search Again", systemImage: "doc.text.magnifyingglass") { Task { await load() } }.help("Find memory files again with Spotlight") }
        }
        .onChange(of: bulk.ids) {
            guard bulk.count == 1, let e = rows.first(where: { bulk.contains($0.id) })?.entry else { return }
            model.info = InfoItem(e.url.lastPathComponent, term: .claudeMD,
                                  facts: [("Type", e.type.rawValue), ("Path", shortPath(e.url)),
                                          ("Lines", e.exists ? "\(e.lines) (recommended under \(e.type.lineLimit))" : "missing"),
                                          ("Loaded", e.loaded ? "\(formatTokens(e.tokens)) tokens every session" : "on demand")],
                                  file: e.exists ? e.url : nil, text: e.exists ? (readText(e.url).map { String($0.prefix(20_000)) } ?? "Can't read this file.") : e.type.purpose,
                                  notes: e.recommendations)
        }
        .onDeleteCommand {
            let urls = rows.filter { bulk.contains($0.id) && $0.entry.exists }.map(\.entry.url)
            if !urls.isEmpty { model.propose("Move \(urls.count) to the Trash", Memory.removal(urls)) }
        }
        .task(id: model.snapshot.scannedAt) { await load() }
        .sheet(item: Binding(get: { editing.map(EditTarget.init) }, set: { editing = $0?.url })) { FileEditorSheet(url: $0.url) }
    }

    private func target(_ r: MemRow) -> Target? {
        model.snapshot.instructions.first { $0.url == r.entry.url }.flatMap { ScopeMove.target(of: $0) }
    }

    private func scopeInk(_ r: MemRow) -> Color {
        if let t = target(r) { return t.ink }
        return switch r.level { case "User": Ink.user; case "Project": Ink.project; case "Local": Ink.local; default: Ink.plugin }
    }

    @ViewBuilder private func actions(_ e: MemoryEntry) -> some View {
        if e.exists {
            Button("Edit") { editing = e.url }
            ResetButton(what: e.url.lastPathComponent, explanation: "Replaces it with the default \(e.type.rawValue) template. The current version is backed up.") {
                try Memory.reset(e.url, type: e.type)
            }
            Button("Move to Trash", role: .destructive) { model.propose("Move \(shortPath(e.url)) to the Trash", Memory.removal([e.url])) }
            if e.type == .memoryTopic || e.type == .memoryIndex {
                let dir = e.url.deletingLastPathComponent()
                Button("Move Memory Folder to Trash", role: .destructive) {
                    let files = ([dir.appending(path: "MEMORY.md")] + Memory.topicFiles(dir)).filter { exists($0) }
                    model.propose("Move the memory folder \(shortPath(dir)) to the Trash (\(files.count) files: " + files.map(\.lastPathComponent).joined(separator: ", ") + ")", .trash([dir]))
                }
            }
        } else {
            Button("Create from template") {
                do { try Memory.reset(e.url, type: e.type); model.didAct("Created \(e.url.lastPathComponent)", []); editing = e.url }
                catch { model.actionError = error.localizedDescription }
            }
        }
    }

    /// Path relative to its project/user root, so `.claude/rules/x.md` reads clearly.
    private func relativeName(_ e: MemoryEntry) -> String {
        let p = shortPath(e.url)
        if let proj = model.snapshot.projects.map(\.path).filter({ e.url.path.hasPrefix($0 + "/") }).max(by: { $0.count < $1.count }), proj != Paths.home.path {
            return String(e.url.path.dropFirst(proj.count + 1))
        }
        return p
    }

    private func load() async {
        loading = true
        agentFiles = await AgentFiles.find(extra: []).map(\.url)
        loading = false
    }
}

private struct MemRow: Identifiable {
    let entry: MemoryEntry
    let project: String
    let name: String
    var id: String { entry.id }
    var type: String { entry.type.rawValue }
    var size: Int { (try? entry.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
    var modified: Date { entry.modified ?? .distantPast }
    var level: String {
        switch entry.type {
        case .userClaudeMD: "User"
        case .projectClaudeMD, .rule: "Project"
        case .localMD: "Local"
        case .memoryIndex, .memoryTopic: "Auto-memory"
        case .otherAgent: "Other agent"
        }
    }
}

struct EditTarget: Identifiable { let url: URL; var id: String { url.path } }
