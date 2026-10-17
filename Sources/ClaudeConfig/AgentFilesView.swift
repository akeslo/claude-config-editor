import ConfigCore
import SwiftUI

/// Every CLAUDE.md, AGENTS.md and similar agent instruction file on this Mac, with a read-only preview.
struct AgentFilesView: View {
    @Environment(AppModel.self) private var model
    @State private var files: [AgentFile] = []
    @State private var loading = true
    @State private var selection: AgentFile.ID?
    @State private var search = ""
    @State private var agent = "All"
    @State private var ext = "All"
    @State private var sort = [KeyPathComparator(\AgentFile.url.path)]

    var body: some View {
        let shown = files.filter {
            (agent == "All" || $0.agent == agent) && (ext == "All" || $0.suffix == ext) && (search.isEmpty || $0.url.path.localizedCaseInsensitiveContains(search))
        }.sorted(using: sort)
        HStack(spacing: 0) {
            Table(shown, selection: $selection, sortOrder: $sort) {
                TableColumn("File", value: \.url.path) { f in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(f.url.deletingLastPathComponent().lastPathComponent + "/" + f.url.lastPathComponent).lineLimit(1)
                        Text(shortPath(f.url.deletingLastPathComponent())).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                    }.help(f.url.path)
                }
                TableColumn("Agent", value: \.agent) { Text($0.agent) }.width(110)
                TableColumn("Size", value: \.size) { Text(formatBytes($0.size)).monospacedDigit() }.width(70)
                TableColumn("Modified") { f in Text(f.modified.map { $0.formatted(.relative(presentation: .named)) } ?? "") }.width(110)
            }
            .contextMenu(forSelectionType: AgentFile.ID.self) { ids in
                if let f = files.first(where: { ids.contains($0.id) }) { TrashButton(url: f.url) }
            }
            .overlay { if loading { ProgressView("Searching with Spotlight…") } else if shown.isEmpty { ContentUnavailableView.search } }
            .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            preview.frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
        }
        .searchable(text: $search, prompt: "Filter by path")
        .toolbar {
            Picker("Agent", selection: $agent) {
                Text("All").tag("All")
                ForEach(Set(AgentFiles.names.values).sorted(), id: \.self) { Text($0).tag($0) }
            }
            Picker("Extension", selection: $ext) {
                Text("All").tag("All")
                ForEach(Set(files.map(\.suffix)).sorted(), id: \.self) { Text($0.isEmpty ? "Live file" : $0).tag($0) }
            }
            Text("\(shown.count) files").foregroundStyle(.secondary)
            Button("Search again", systemImage: "doc.text.magnifyingglass") { Task { await load() } }
        }
        .task { await load() }
        .onChange(of: selection) {
            guard let f = files.first(where: { $0.id == selection }) else { return }
            let isLocal = AgentFiles.baseName(f.url.lastPathComponent) == "CLAUDE.local.md"
            model.info = InfoItem(f.url.lastPathComponent, term: isLocal ? .claudeLocalMD : .claudeMD, facts: [
                ("Path", shortPath(f.url)), ("Read by", f.agent), ("Size", formatBytes(f.size)),
                ("Context", formatTokens(estimateTokens(readText(f.url) ?? ""))),
            ], file: f.url)
        }
    }

    @ViewBuilder private var preview: some View {
        if let f = files.first(where: { $0.id == selection }) {
            ScrollView {
                Text(readText(f.url) ?? "Can't read this file.")
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
        } else {
            ContentUnavailableView("Select a file", systemImage: "doc.text", description: Text("Its contents show here."))
        }
    }

    private func load() async {
        loading = true
        files = await AgentFiles.find()
        loading = false
    }
}
