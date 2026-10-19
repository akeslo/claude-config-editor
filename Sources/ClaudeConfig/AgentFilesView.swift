import ConfigCore
import SwiftUI

/// Memory: every CLAUDE.md, rule, auto-memory and other-agent file, grouped by project, with guidance and edit/reset/delete.
struct AgentFilesView: View {
    @Environment(AppModel.self) private var model
    @State private var agentFiles: [URL] = []
    @State private var loading = true
    @State private var selection: String?
    @State private var search = ""
    @State private var editing: URL?
    @State private var expanded: Set<String> = ["user"]
    @State private var showEmpty = false
    @State private var bulk = BulkSelection<String>()
    @State private var order = [KeyPathComparator(\MemRow.modified, order: .reverse)]
    @State private var project = "All"
    @State private var type: MemoryType?
    @State private var level = "All"

    var body: some View {
        let all = Memory.groups(instructions: model.snapshot.instructions, agentFiles: agentFiles, projects: model.snapshot.projects.map(\.path))
        let emptyCount = all.filter(\.isEmpty).count
        let groups = showEmpty || !search.isEmpty ? all : all.filter { !$0.isEmpty }
        let rows = groups.flatMap { g in g.entries.map { MemRow(entry: $0, project: g.title, name: relativeName($0)) } }
            .filter { project == "All" || $0.project == project }
            .filter { type == nil || $0.entry.type == type }
            .filter { level == "All" || $0.level == level }
            .filter { search.isEmpty || [$0.name, $0.entry.url.path, $0.entry.type.rawValue].contains { $0.localizedCaseInsensitiveContains(search) }
                || $0.entry.recommendations.contains { $0.localizedCaseInsensitiveContains(search) } }
            .sorted(using: order)
        let selected = rows.first { $0.id == selection }?.entry
        let visible = rows.map(\.id)
        let picked = rows.map(\.entry).filter { bulk.contains($0.id) && $0.exists }
        HSplitView {
            VStack(spacing: 0) {
                HStack(spacing: Space.m) {
                    TextField("Filter memory", text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 220)
                    Picker("Project", selection: $project) {
                        Text("All projects").tag("All")
                        ForEach(groups.map(\.title), id: \.self) { Text($0).tag($0) }
                    }.fixedSize()
                    Picker("Type", selection: $type) {
                        Text("All types").tag(MemoryType?.none)
                        ForEach(MemoryType.allCases, id: \.self) { Text($0.rawValue).tag(MemoryType?.some($0)) }
                    }.fixedSize()
                    Picker("Level", selection: $level) {
                        ForEach(["All", "User", "Project", "Local", "Auto-memory", "Other agent"], id: \.self) { Text($0 == "All" ? "All levels" : $0).tag($0) }
                    }.fixedSize()
                    Spacer()
                    if emptyCount > 0 {
                        Toggle("Show empty (\(emptyCount))", isOn: $showEmpty).toggleStyle(.checkbox).font(.caption)
                            .help("Folders whose files add ≈0 tokens to context and need no cleanup")
                    }
                }.padding(Space.m)
                BulkBar(sel: $bulk, visible: visible, actions: [
                    BulkAction(title: "Move to Trash…", icon: "trash", check: bulkCheck(picked) { trashRefusal($0.url) }) {
                        model.propose("Move \(picked.count) file\(picked.count == 1 ? "" : "s") to the Trash: " + picked.map { shortPath($0.url) }.joined(separator: ", "),
                                      Memory.removal(picked.map(\.url)))
                    },
                    BulkAction(title: "Copy paths", icon: "doc.on.clipboard", check: bulkCheck(picked) { _ in nil }) { copy(picked.map(\.url.path).joined(separator: "\n")) },
                ])
                Table(rows, selection: $selection, sortOrder: $order) {
                    TableColumn("", value: \MemRow.name) { (r: MemRow) in SelectBox(sel: $bulk, id: r.id, visible: visible, name: r.name) }.width(22)
                    TableColumn("Name", value: \MemRow.name) { (r: MemRow) in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 4) {
                                if !r.entry.recommendations.isEmpty { Image(systemName: "lightbulb.fill").foregroundStyle(.orange).help(r.entry.recommendations.joined(separator: "\n")) }
                                Text(r.name).font(.body.weight(.medium)).foregroundStyle(r.entry.exists ? .primary : .secondary)
                                if let s = r.entry.stale { Image(systemName: "clock.badge.exclamationmark").foregroundStyle(.orange).help(s) }
                                else if r.entry.exists { StaleBadge(Staleness.of(modified: r.entry.modified)) }
                                else { Text("missing").font(.caption2).foregroundStyle(.tertiary) }
                            }
                            Text(r.entry.type.rawValue + " · " + r.level).font(.caption).foregroundStyle(.secondary)
                        }
                        .contextMenu { actions(r.entry) }
                    }.width(min: 200, ideal: 300)
                    TableColumn("Project", value: \MemRow.project) { (r: MemRow) in Text(r.project).foregroundStyle(.secondary).lineLimit(1) }.width(min: 80, ideal: 120)
                    TableColumn("Size", value: \MemRow.size) { (r: MemRow) in
                        Text(r.entry.exists ? formatBytes(Int64(r.size)) : "—").monospacedDigit().foregroundStyle(.secondary)
                            .help(r.entry.loaded ? "\(formatTokens(r.entry.tokens)) tokens every session" : "Not loaded into every session")
                    }.width(min: 50, ideal: 70)
                    TableColumn("Last updated", value: \MemRow.modified) { (r: MemRow) in
                        Text(r.entry.modified.map { $0.formatted(.relative(presentation: .named)) } ?? "—").foregroundStyle(.secondary)
                    }.width(min: 80, ideal: 110)
                }
            }
            .overlay { if loading && rows.isEmpty { ProgressView("Searching with Spotlight…") } }
            .frame(minWidth: 560, maxHeight: .infinity)
            detail(selected).frame(minWidth: 340, maxWidth: .infinity, maxHeight: .infinity)
        }
        .toolbar { Button("Search again", systemImage: "doc.text.magnifyingglass") { Task { await load() } } }
        .task(id: model.snapshot.scannedAt) { await load() }
        .sheet(item: Binding(get: { editing.map(EditTarget.init) }, set: { editing = $0?.url })) { FileEditorSheet(url: $0.url) }
    }

    @ViewBuilder private func actions(_ e: MemoryEntry) -> some View {
        if e.exists {
            Button("Edit…") { editing = e.url }
            ResetButton(what: e.url.lastPathComponent, explanation: "Replaces it with the default \(e.type.rawValue) template. The current version is backed up.") {
                try Memory.reset(e.url, type: e.type)
            }
            Button("Move to Trash…", role: .destructive) { model.propose("Move \(shortPath(e.url)) to the Trash", Memory.removal([e.url])) }
            if e.type == .memoryTopic || e.type == .memoryIndex {
                let dir = e.url.deletingLastPathComponent()
                Button("Move whole memory folder to Trash…", role: .destructive) {
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

    @ViewBuilder private func detail(_ e: MemoryEntry?) -> some View {
        if let e {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.m) {
                    Text(e.url.lastPathComponent).font(.title2.weight(.semibold))
                    Text(shortPath(e.url)).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    HStack { actions(e) }
                    GroupBox(e.type.rawValue) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(e.type.purpose)
                            ForEach(e.type.whatToPut, id: \.self) { Label($0, systemImage: "checkmark").font(.callout) }
                            Text("Recommended: under \(e.type.lineLimit) lines" + (e.exists ? " · yours: \(e.lines)" : ""))
                                .font(.caption).foregroundStyle(e.lines > e.type.lineLimit ? .orange : .secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if !e.recommendations.isEmpty {
                        GroupBox("Recommendations") {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(e.recommendations, id: \.self) { Label($0, systemImage: "lightbulb").foregroundStyle(.orange) }
                                ForEach(e.actions) { a in Button(a.button) { model.propose(a.title, a.fix) } }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    if e.exists {
                        GroupBox("Contents") {
                            Text(readText(e.url) ?? "Can't read this file.").font(.system(.callout, design: .monospaced))
                                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }.padding(Space.l)
            }
        } else {
            ContentUnavailableView("Select a file", systemImage: "doc.text", description: Text("See what it's for, recommendations, and edit, reset or delete it."))
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

private struct EditTarget: Identifiable { let url: URL; var id: String { url.path } }
