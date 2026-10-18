import ConfigCore
import SwiftUI

struct StorageView: View {
    @Environment(AppModel.self) private var model
    @State private var areaID: StorageArea.ID?
    @State private var items: [Item] = []
    @State private var picked = Set<Item.ID>()
    @State private var loadingItems = false
    @State private var search = ""
    @State private var areaSort = [KeyPathComparator(\StorageArea.bytes, order: .reverse)]
    @State private var itemSort = [KeyPathComparator(\Item.bytes, order: .reverse)]

    struct Item: Identifiable {
        var id: String { url.path }
        let url: URL
        var bytes: Int64
        let modified: Date?
        var name: String { url.lastPathComponent }
    }

    var body: some View {
        let total = max(1, model.storage.reduce(0) { $0 + $1.bytes })
        VSplitView {
            // One filter for both tables: a second .searchable in the same view would fight the first.
            Table(model.storage.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.url.path.localizedCaseInsensitiveContains(search) }.sorted(using: areaSort),
                  selection: $areaID, sortOrder: $areaSort) {
                TableColumn("Location", value: \.name) { a in
                    Label(a.name, systemImage: a.safety == .keep ? "lock" : a.safety == .unknown ? "questionmark.folder" : "folder")
                        .help(a.term.tooltip)
                }
                TableColumn("Size", value: \.bytes) { a in
                    HStack {
                        ProgressView(value: Double(a.bytes), total: Double(total)).frame(width: 70)
                        Text(a.bytes == 0 && model.measuringStorage ? "…" : formatBytes(a.bytes)).monospacedDigit()
                    }
                }.width(150)
                TableColumn("Items", value: \.itemCount) { Text("\($0.itemCount)").monospacedDigit() }.width(50)
                TableColumn("Oldest", value: \.oldest, comparator: OptionalDateComparator()) { Text(relative($0.oldest)) }.width(110)
                TableColumn("Safety", value: \.safety.rawValue) { a in
                    Text(a.safety.rawValue).foregroundStyle(a.safety == .safe ? .green : a.safety == .keep ? .secondary : .orange)
                        .help(safetyHelp(a.safety))
                }.width(110)
                TableColumn("Auto-cleaned") { a in
                    Text(a.autoCleaned ? "Yes (\(model.snapshot.cleanupPeriodDays) d)" : "No")
                        .help(a.autoCleaned ? Term.cleanupPeriod.tooltip : "Claude does not clean this location automatically.")
                }.width(100)
            }
            .frame(minHeight: 220)

            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(area.map { "\($0.name): \(shortPath($0.url))" } ?? "Select a location to see what is inside").font(.headline)
                    if loadingItems { ProgressView().controlSize(.small) }
                    Spacer()
                    if let area {
                        Button("Reveal") { reveal(area.url) }
                        if area.safety != .keep {
                            let stale = items.filter { staleness($0).level == .stale }.map(\.url)
                            if !stale.isEmpty { ConfirmDeleteButton(urls: stale, label: "Clean up \(stale.count) stale…") }
                            if !picked.isEmpty { ConfirmDeleteButton(urls: items.filter { picked.contains($0.id) }.map(\.url), label: "Delete \(picked.count)…") }
                        } else {
                            Text("Claude needs this; view only").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(Space.s)
                Table(items.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }.sorted(using: itemSort), selection: $picked, sortOrder: $itemSort) {
                    TableColumn("Name", value: \.name) { Text($0.name).lineLimit(1).truncationMode(.middle).help($0.url.path) }
                    TableColumn("Size", value: \.bytes) { Text(formatBytes($0.bytes)).monospacedDigit() }.width(90)
                    TableColumn("Modified", value: \.modified, comparator: OptionalDateComparator()) { i in
                        HStack { Text(relative(i.modified)); StaleBadge(staleness(i)) }
                    }.width(170)
                }
                .contextMenu(forSelectionType: Item.ID.self) { ids in
                    if let id = ids.first { Button("Reveal in Finder") { reveal(URL(filePath: id)) } }
                    if !ids.isEmpty, let area, area.safety != .keep {
                        ConfirmDeleteButton(urls: ids.map { URL(filePath: $0) })
                    }
                }
            }
            .frame(minHeight: 200)
        }
        .searchable(text: $search, prompt: "Filter locations and items")
        .onChange(of: model.lastAction?.title) { if let a = area { picked = []; Task { await loadItems(a.url) } } }
        .onChange(of: areaID) {
            picked = []
            guard let area else { items = []; return }
            model.info = InfoItem(area.name, term: area.term,
                                  facts: [("Path", shortPath(area.url)), ("Size", formatBytes(area.bytes)), ("Safety", area.safety.rawValue)],
                                  file: area.url)
            Task { await loadItems(area.url) }
        }
    }

    private func staleness(_ i: Item) -> (level: Staleness, reason: String) { Staleness.of(modified: i.modified) }

    private var area: StorageArea? { model.storage.first { $0.id == areaID } }

    private func loadItems(_ url: URL) async {
        loadingItems = true
        items = children(url).map { Item(url: $0, bytes: 0, modified: modificationDate($0)) }
        let measured = await Task.detached { [items] in items.map { Item(url: $0.url, bytes: directorySize($0.url), modified: $0.modified) } }.value
        if areaID == url.path { items = measured.sorted { $0.bytes > $1.bytes } }
        loadingItems = false
    }

    private func safetyHelp(_ s: StorageArea.Safety) -> String {
        switch s {
        case .safe: "Rebuildable or temporary. Clearing it does not lose settings."
        case .care: "Clearing loses history (resume, rewind) or backups. Check first."
        case .keep: "Claude needs this. View only; use the claude CLI to change it."
        case .unknown: "Not part of Claude Code's documented layout; may belong to a plugin or tool."
        }
    }
}

struct ProjectsView: View {
    @Environment(AppModel.self) private var model
    @State private var selection = Set<Project.ID>()
    @State private var sort = [KeyPathComparator(\Row.total, order: .reverse)]
    @State private var search = ""

    struct Row: Identifiable {
        var id: String { p.path }
        let p: Project
        let dataBytes: Int64
        var total: Int64 { dataBytes + Int64(p.entryBytes) }
        var name: String { p.path }
        var sessions: Int { p.transcriptCount }
        var last: Date { p.lastSession ?? .distantPast }
    }

    var body: some View {
        let rows = model.snapshot.projects
            .filter { search.isEmpty || $0.path.localizedCaseInsensitiveContains(search) }
            .map { Row(p: $0, dataBytes: model.projectBytes[$0.path] ?? 0) }
            .sorted(using: sort)
        Table(rows, selection: $selection, sortOrder: $sort) {
            TableColumn("Folder", value: \.name) { r in
                HStack {
                    if !r.p.folderExists { Image(systemName: "folder.badge.questionmark").foregroundStyle(.orange).help("This folder no longer exists.") }
                    Text(shortPath(URL(filePath: r.p.path))).lineLimit(1).truncationMode(.middle)
                    StaleBadge(stale(r.p))
                }
            }
            TableColumn("Sessions", value: \.sessions) { Text("\($0.sessions)").monospacedDigit().help(Term.transcripts.tooltip) }.width(70)
            TableColumn("Transcripts & memory", value: \.dataBytes) { Text(model.measuringStorage && $0.dataBytes == 0 ? "…" : formatBytes($0.dataBytes)).monospacedDigit() }.width(140)
            TableColumn("Entry", value: \.total) { Text(formatBytes(Int64($0.p.entryBytes))).monospacedDigit().help(Term.project.tooltip) }.width(80)
            TableColumn("Allowed tools") { Text("\($0.p.allowedTools.count)").monospacedDigit().help(Term.allowedTools.tooltip) }.width(90)
            TableColumn("Last session", value: \.last) { Text(relative($0.p.lastSession)) }.width(120)
        }
        .searchable(text: $search, prompt: "Filter folders")
        .contextMenu(forSelectionType: Project.ID.self) { ids in
            if let path = ids.first {
                Button("Reveal transcripts") { reveal(Paths.projectDataDir(for: path)) }
                Button("Purge…") { purge(ids) }.disabled(ids.count != 1)
                ConfirmDeleteButton(urls: ids.map { Paths.projectDataDir(for: $0) }.filter(exists), label: "Delete Transcripts…")
            }
        }
        .toolbar {
            let staleDirs = model.snapshot.projects.filter { stale($0).level == .stale }.map { Paths.projectDataDir(for: $0.path) }.filter(exists)
            if !staleDirs.isEmpty {
                ConfirmDeleteButton(urls: staleDirs, label: "Clean up \(staleDirs.count) stale…")
                    .help("Deletes transcripts and memory of projects whose folder is gone or with no session in 90 days. Backed up; undoable.")
            }
            if !selection.isEmpty {
                ConfirmDeleteButton(urls: selection.map { Paths.projectDataDir(for: $0) }.filter(exists), label: "Delete Transcripts…")
            }
            Button("Purge…") { purge(selection) }
                .disabled(selection.count != 1)
                .help("Select one project. Deletes everything Claude stores for the selected project: transcripts, memory, history, trust and allowed tools. Shows a dry run first.")
        }
        .onChange(of: selection) {
            guard selection.count == 1, let p = model.snapshot.projects.first(where: { $0.path == selection.first }) else { return }
            model.info = InfoItem(shortPath(URL(filePath: p.path)), term: .project, facts: [
                ("Exists", p.folderExists ? "Yes" : "No"),
                ("Trusted", p.trusted ? "Yes" : "No"),
                ("Sessions", "\(p.transcriptCount)"),
                ("Transcripts", formatBytes(model.projectBytes[p.path] ?? 0)),
                ("Entry in ~/.claude.json", formatBytes(Int64(p.entryBytes))),
                ("Local MCP servers", p.mcpServerNames.joined(separator: ", ").ifEmpty("none")),
            ], file: p.dataDir, text: p.allowedTools.isEmpty ? nil : "Allowed tools:\n" + p.allowedTools.joined(separator: "\n"))
        }
    }

    private func stale(_ p: Project) -> (level: Staleness, reason: String) { Staleness.of(modified: p.lastSession, pathExists: p.folderExists) }

    private func purge(_ ids: Set<String>) {
        guard ids.count == 1, let path = ids.first else { return }
        model.propose("Purge \(shortPath(URL(filePath: path)))", .cli(args: ["purge", path, "--yes"], dryRun: ["purge", path, "--dry-run"], cwd: nil))
    }
}

extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}
