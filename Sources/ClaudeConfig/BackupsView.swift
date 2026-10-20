import ConfigCore
import SwiftUI

/// Backups: every *.bak / *-bak-* / *~ copy left next to a Claude config file, with a diff against its original and restore/reveal/trash.
struct BackupsView: View {
    @Environment(AppModel.self) private var model
    @State private var files: [BackupFile] = []
    @State private var loading = true
    @State private var search = ""
    @State private var sel = Set<String>()
    @State private var sort = [KeyPathComparator(\BackupFile.modifiedSort, order: .reverse)]
    @State private var restoring: BackupFile?

    var body: some View {
        let shown = (search.isEmpty ? files : files.filter { $0.url.path.localizedCaseInsensitiveContains(search) }).sorted(using: sort)
        Table(shown, selection: $sel, sortOrder: $sort) {
            TableColumn("Backup", value: \.name) { (b: BackupFile) in Text(b.url.lastPathComponent).fontWeight(.medium).lineLimit(1).truncationMode(.middle) }
                .width(min: 180, ideal: 320)
            TableColumn("Original") { (b: BackupFile) in
                Text(b.original.map(shortPath) ?? "unknown").foregroundStyle(b.original == nil ? Ink.warning : .secondary).lineLimit(1).truncationMode(.middle)
            }.width(min: 160, ideal: 360)
            TableColumn("Size", value: \.size) { (b: BackupFile) in Text(formatBytes(b.size)).monospacedDigit().foregroundStyle(.secondary) }.width(70)
            TableColumn("Modified", value: \.modifiedSort) { (b: BackupFile) in
                Text(b.modified?.formatted(date: .abbreviated, time: .shortened) ?? "—").foregroundStyle(.secondary).lineLimit(1)
            }.width(min: 120, ideal: 150)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            let picked = shown.filter { ids.contains($0.id) }
            if picked.count == 1, let b = picked.first {
                Button("Restore…") { restoring = b }.disabled(b.original == nil)
                Button("Reveal in Finder") { reveal(b.url) }
            }
            if !picked.isEmpty {
                Button("Copy Path\(picked.count == 1 ? "" : "s")") { copy(picked.map(\.url.path).joined(separator: "\n")) }
                Divider()
                Button(picked.count == 1 ? "Move to Trash…" : "Move \(picked.count) to Trash…", role: .destructive) { trash(picked) }
            }
        } primaryAction: { ids in
            if let b = shown.first(where: { ids.contains($0.id) }), b.original != nil { restoring = b }
        }
        .onDeleteCommand { trash(shown.filter { sel.contains($0.id) }) }
        .overlay {
            if loading && files.isEmpty { ProgressView("Looking for backups…") }
            else if shown.isEmpty { ContentUnavailableView("No backups", systemImage: "clock.arrow.circlepath", description: Text("No *.bak, *-bak-*, *.orig or *~ files next to Claude config.")) }
        }
        .searchable(text: $search, prompt: "Filter by path")
        .toolbar { Button("Scan Again", systemImage: "arrow.clockwise") { Task { await load() } }.help("Look for backup files again") }
        .task(id: model.snapshot.scannedAt) { await load() }
        .onChange(of: sel) {
            guard sel.count == 1, let b = shown.first(where: { sel.contains($0.id) }) else { return }
            let d = BackupFiles.diff(b)
            model.info = InfoItem(b.url.lastPathComponent, term: .settings,
                                  facts: [("Original", b.original.map(shortPath) ?? "unknown"), ("Size", formatBytes(b.size)),
                                          ("Modified", b.modified?.formatted(date: .abbreviated, time: .shortened) ?? "—")],
                                  file: b.url, text: d.isEmpty ? "Identical to the current original." : "Diff: current original → this backup\n\n" + d)
        }
        .confirmationDialog("Restore \(restoring?.original?.lastPathComponent ?? "")?", isPresented: Binding(get: { restoring != nil }, set: { if !$0 { restoring = nil } }), presenting: restoring) { b in
            Button("Restore", role: .destructive) { restore(b) }
        } message: { b in
            Text("Overwrites \(b.original.map(shortPath) ?? "?") with \(b.url.lastPathComponent). The current file is backed up to ~/.claude/config-editor-backups/undo first.")
        }
    }

    private func trash(_ picked: [BackupFile]) {
        guard !picked.isEmpty else { return }
        model.proposeBulk("Move \(picked.count) backup\(picked.count == 1 ? "" : "s") to the Trash",
                          bulkPlan(picked, label: { shortPath($0.url) }, skip: { trashRefusal($0.url) }) { .trash([$0.url]) })
    }

    private func restore(_ b: BackupFile) {
        do {
            let snap = try BackupFiles.restore(b)
            model.didAct("Restored \(b.original?.lastPathComponent ?? "") from \(b.url.lastPathComponent)", snap.map { [$0] } ?? [])
        } catch { model.actionError = error.localizedDescription }
    }

    /// `open -R` selects the file in Finder without the app activating itself.
    private func reveal(_ url: URL) {
        let p = Process()
        p.executableURL = URL(filePath: "/usr/bin/open")
        p.arguments = ["-R", url.path]
        try? p.run()
    }

    private func load() async {
        loading = true
        let r = BackupFiles.roots(projects: model.snapshot.projects.map(\.path))
        let projects = model.snapshot.projects.map { URL(filePath: $0.path) }
        files = await Task.detached(priority: .utility) { BackupFiles.scan(deep: r.deep, shallow: r.shallow, projects: projects) }.value
        loading = false
    }
}

private extension BackupFile {
    var name: String { url.lastPathComponent }
    var modifiedSort: Date { modified ?? .distantPast }
}
