import ConfigCore
import SwiftUI

/// Backups: every *.bak / *-bak-* / *~ copy left next to a Claude config file, with a diff against its original and restore/reveal/trash.
struct BackupsView: View {
    @Environment(AppModel.self) private var model
    @State private var files: [BackupFile] = []
    @State private var loading = true
    @State private var selection: String?
    @State private var search = ""
    @State private var bulk = BulkSelection<String>()
    @State private var restoring: BackupFile?

    var body: some View {
        let shown = search.isEmpty ? files : files.filter { $0.url.path.localizedCaseInsensitiveContains(search) }
        let visible = shown.map(\.id)
        let picked = files.filter { bulk.contains($0.id) }
        HSplitView {
            List(selection: $selection) {
                ForEach(shown) { b in
                    HStack(spacing: 6) {
                        SelectBox(sel: $bulk, id: b.id, visible: visible, name: b.url.lastPathComponent)
                        row(b)
                    }.tag(b.id)
                }
            }
            .bulkSelectable($bulk, visible: visible, actions: [
                BulkAction(title: "Move to Trash…", icon: "trash", check: bulkCheck(picked) { _ in nil }) {
                    model.proposeBulk("Move \(picked.count) backup\(picked.count == 1 ? "" : "s") to the Trash",
                                      bulkPlan(picked, label: { shortPath($0.url) }, skip: { trashRefusal($0.url) }) { .trash([$0.url]) })
                },
                BulkAction(title: "Copy paths", icon: "doc.on.clipboard", check: bulkCheck(picked) { _ in nil }) { copy(picked.map(\.url.path).joined(separator: "\n")) },
            ])
            .overlay {
                if loading && files.isEmpty { ProgressView("Looking for backups…") }
                else if shown.isEmpty { ContentUnavailableView("No backups", systemImage: "clock.arrow.circlepath", description: Text("No *.bak, *-bak-*, *.orig or *~ files next to Claude config.")) }
            }
            .frame(minWidth: 460, maxHeight: .infinity)
            detail(shown.first { $0.id == selection }).frame(minWidth: 340, maxWidth: .infinity, maxHeight: .infinity)
        }
        .searchable(text: $search, prompt: "Filter by path")
        .toolbar { Button("Scan again", systemImage: "arrow.clockwise") { Task { await load() } } }
        .task(id: model.snapshot.scannedAt) { await load() }
        .confirmationDialog("Restore \(restoring?.original?.lastPathComponent ?? "")?", isPresented: Binding(get: { restoring != nil }, set: { if !$0 { restoring = nil } }), presenting: restoring) { b in
            Button("Restore", role: .destructive) { restore(b) }
        } message: { b in
            Text("Overwrites \(b.original.map(shortPath) ?? "?") with \(b.url.lastPathComponent). The current file is backed up to ~/.claude/config-editor-backups/undo first.")
        }
    }

    private func row(_ b: BackupFile) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(b.url.lastPathComponent)
                Text(shortPath(b.url.deletingLastPathComponent())).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Text(formatBytes(b.size)).monospacedDigit().font(.caption).frame(width: 70, alignment: .trailing)
            Text(b.modified?.formatted(date: .abbreviated, time: .shortened) ?? "").font(.caption).foregroundStyle(.secondary).frame(width: 140, alignment: .trailing)
        }
        .contextMenu { actions(b) }
    }

    @ViewBuilder private func actions(_ b: BackupFile) -> some View {
        Button("Restore…") { restoring = b }.disabled(b.original == nil).help(b.original == nil ? "Original location unknown" : "Copy this backup over its original")
        Button("Reveal in Finder") { reveal(b.url) }
        Button("Move to Trash…", role: .destructive) {
            model.proposeBulk("Move \(b.url.lastPathComponent) to the Trash", bulkPlan([b], label: { shortPath($0.url) }, skip: { trashRefusal($0.url) }) { .trash([$0.url]) })
        }
    }

    @ViewBuilder private func detail(_ b: BackupFile?) -> some View {
        if let b {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.m) {
                    Text(b.url.lastPathComponent).font(.title2.weight(.semibold))
                    Text(shortPath(b.url)).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    Text(b.original.map { "Shadows " + shortPath($0) } ?? "Original location unknown").font(.callout).foregroundStyle(b.original == nil ? .orange : .primary)
                    Text("\(formatBytes(b.size)) · \(b.modified?.formatted(date: .abbreviated, time: .shortened) ?? "unknown date")").font(.caption).foregroundStyle(.secondary)
                    HStack { actions(b) }
                    GroupBox("Diff: current original → this backup") {
                        let d = BackupFiles.diff(b)
                        VStack(alignment: .leading, spacing: 0) {
                            if d.isEmpty { Text("Identical to the current original.").foregroundStyle(.secondary) }
                            ForEach(Array(d.split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) { _, line in
                                Text(line.isEmpty ? " " : String(line)).foregroundStyle(line.hasPrefix("+") ? .green : line.hasPrefix("-") ? .red : line.hasPrefix("@@") ? .secondary : .primary)
                            }
                        }
                        .font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.padding(Space.l)
            }
        } else {
            ContentUnavailableView("Select a backup", systemImage: "clock.arrow.circlepath", description: Text("See its diff against the current file, then restore, reveal or trash it."))
        }
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
