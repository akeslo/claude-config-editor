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

    var body: some View {
        let all = Memory.groups(instructions: model.snapshot.instructions, agentFiles: agentFiles, projects: model.snapshot.projects.map(\.path))
            .compactMap { g -> MemoryGroup? in
                guard !search.isEmpty else { return g }
                var g = g
                g.entries = g.entries.filter { $0.url.path.localizedCaseInsensitiveContains(search) }
                return g.entries.isEmpty ? nil : g
            }
        let emptyCount = all.filter(\.isEmpty).count
        let groups = showEmpty || !search.isEmpty ? all : all.filter { !$0.isEmpty }
        let selected = groups.flatMap(\.entries).first { $0.id == selection }
        HSplitView {
            List(selection: $selection) {
                ForEach(groups) { g in
                    DisclosureGroup(isExpanded: Binding(get: { !search.isEmpty || expanded.contains(g.id) },
                                                        set: { if $0 { expanded.insert(g.id) } else { expanded.remove(g.id) } })) {
                        ForEach(g.entries) { row($0).tag($0.id) }
                    } label: {
                        HStack {
                            Label(g.title, systemImage: g.path == nil ? "person.crop.circle" : "folder")
                                .help(g.path ?? "Applies to every project")
                            Spacer()
                            Text(formatTokens(g.tokens)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if emptyCount > 0 {
                    Toggle("Show empty (\(emptyCount))", isOn: $showEmpty).toggleStyle(.checkbox).font(.caption)
                        .help("Folders whose files add ≈0 tokens to context and need no cleanup")
                        .frame(maxWidth: .infinity, alignment: .leading).padding(6).background(.bar)
                }
            }
            .overlay { if loading && groups.isEmpty { ProgressView("Searching with Spotlight…") } }
            .frame(minWidth: 460, maxHeight: .infinity)
            detail(selected).frame(minWidth: 340, maxWidth: .infinity, maxHeight: .infinity)
        }
        .searchable(text: $search, prompt: "Filter by path")
        .toolbar { Button("Search again", systemImage: "doc.text.magnifyingglass") { Task { await load() } } }
        .task(id: model.snapshot.scannedAt) { await load() }
        .sheet(item: Binding(get: { editing.map(EditTarget.init) }, set: { editing = $0?.url })) { FileEditorSheet(url: $0.url) }
    }

    private func row(_ e: MemoryEntry) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    if !e.recommendations.isEmpty { Image(systemName: "lightbulb.fill").foregroundStyle(.orange).help(e.recommendations.joined(separator: "\n")) }
                    Text(relativeName(e)).foregroundStyle(e.exists ? .primary : .secondary)
                    if e.exists { StaleBadge(Staleness.of(modified: e.modified)) } else { Text("missing").font(.caption2).foregroundStyle(.tertiary) }
                }
                Text(e.type.rawValue).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if e.exists {
                Text(e.loaded ? formatTokens(e.tokens) : (e.type == .rule ? "on match" : "not loaded"))
                    .monospacedDigit().foregroundStyle(e.loaded ? .primary : .secondary)
                    .frame(width: 80, alignment: .trailing)
                    .help(e.loaded ? "Tokens this file adds to every session" : "Not loaded into every session")
                VStack(alignment: .trailing, spacing: 1) {
                    Text(e.modified.map { "Modified " + $0.formatted(.relative(presentation: .named)) } ?? "")
                    Text(e.created.map { "Created " + $0.formatted(date: .abbreviated, time: .omitted) } ?? "").foregroundStyle(.secondary)
                }.font(.caption).frame(width: 150, alignment: .trailing)
            }
        }
        .contextMenu { actions(e) }
    }

    @ViewBuilder private func actions(_ e: MemoryEntry) -> some View {
        if e.exists {
            Button("Edit…") { editing = e.url }
            ResetButton(what: e.url.lastPathComponent, explanation: "Replaces it with the default \(e.type.rawValue) template. The current version is backed up.") {
                try Memory.reset(e.url, type: e.type)
            }
            ConfirmDeleteButton(url: e.url)
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

private struct EditTarget: Identifiable { let url: URL; var id: String { url.path } }
