import ConfigCore
import SwiftUI

// Reusable edit/reset/delete pieces. All deletes and writes go through `Backup`, so the undo toast can put things back.

extension AppModel {
    /// Records an undoable action and rescans so every page sees the change.
    func didAct(_ title: String, _ records: [Backup.Record]) {
        lastAction = (title, records)
        actionError = nil
        Task { await refresh() }
    }

    /// Backs up and removes each URL; stops at the first failure (earlier ones stay undoable).
    func trashWithUndo(_ urls: [URL], title: String) {
        var done: [Backup.Record] = []
        do { for u in urls { done.append(try Backup.trash(u)) } } catch { actionError = error.localizedDescription }
        if !done.isEmpty { didAct(title, done) }
    }

    func undoLast() {
        guard let a = lastAction else { return }
        do { for r in a.records.reversed() { try Backup.restore(r) } ; lastAction = nil } catch { actionError = error.localizedDescription }
        Task { await refresh() }
    }
}

/// "Delete…" with a confirm dialog; deleted items go to the config-editor backup folder and can be undone from the toast.
struct ConfirmDeleteButton: View {
    @Environment(AppModel.self) private var model
    let urls: [URL]
    var label = "Delete…"
    @State private var asking = false

    init(url: URL, label: String = "Delete…") { urls = [url]; self.label = label }
    init(urls: [URL], label: String = "Delete…") { self.urls = urls; self.label = label }

    var body: some View {
        let ok = urls.filter { trashRefusal($0) == nil }
        if !ok.isEmpty {
            Button(label, role: .destructive) { asking = true }
                .help("Moves to ~/.claude/backups/config-editor, so it can be undone")
                .confirmationDialog(ok.count == 1 ? "Delete \(ok[0].lastPathComponent)?" : "Delete \(ok.count) items?", isPresented: $asking) {
                    Button("Delete", role: .destructive) { model.trashWithUndo(ok, title: "Deleted \(ok.count == 1 ? ok[0].lastPathComponent : "\(ok.count) items")") }
                } message: { Text("A copy is kept in ~/.claude/backups/config-editor (deleted items; file edits are backed up to ~/.claude/config-editor-backups). Click Undo in the notice that appears to bring it back.") }
        }
    }
}

/// "Reset…" with a confirm dialog. `perform` does the reset (e.g. `updateSettingsKey(file, path: p, value: nil)`) and may return a backup record for undo.
struct ResetButton: View {
    @Environment(AppModel.self) private var model
    let what: String
    var explanation = "This falls back to the default."
    let perform: () throws -> Backup.Record?
    @State private var asking = false

    var body: some View {
        Button("Reset…") { asking = true }
            .confirmationDialog("Reset \(what)?", isPresented: $asking) {
                Button("Reset", role: .destructive) {
                    do { model.didAct("Reset \(what)", try perform().map { [$0] } ?? []) } catch { model.actionError = error.localizedDescription }
                }
            } message: { Text(explanation) }
    }
}

/// Plain-text editor for one file. Save snapshots the old version first and refuses if the file changed on disk since it was opened.
struct FileEditorSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let url: URL
    @State private var text = ""
    @State private var loadedAt: Date?
    @State private var original = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Text(url.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
            TextEditor(text: $text).font(.system(.body, design: .monospaced)).frame(minWidth: 640, minHeight: 420)
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Text(formatTokens(estimateTokens(text))).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }.keyboardShortcut("s").disabled(text == original)
            }
        }
        .padding(Space.l)
        .onAppear {
            original = readText(url) ?? ""
            text = original
            loadedAt = modificationDate(url)
        }
    }

    private func save() {
        do {
            if exists(url), modificationDate(url) != loadedAt { throw SafeWriteError.changedOnDisk }
            let record = exists(url) ? try Backup.snapshot(url) : nil
            try Data(text.utf8).write(to: url, options: .atomic)
            model.didAct("Saved \(url.lastPathComponent)", record.map { [$0] } ?? [])
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

/// Small "Aging"/"Stale" capsule; renders nothing when fresh.
struct StaleBadge: View {
    let level: Staleness
    let reason: String

    init(_ s: (level: Staleness, reason: String)) { level = s.level; reason = s.reason }

    var body: some View {
        if level != .fresh {
            Text(level == .stale ? "Stale" : "Aging")
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background((level == .stale ? Color.orange : Color.yellow).opacity(0.2), in: Capsule())
                .foregroundStyle(level == .stale ? .orange : .secondary)
                .help(reason)
        }
    }
}

/// Bottom toast with Undo for the last action, or the last error. Attached once in RootView.
struct UndoToast: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let err = model.actionError {
            toast { Label(err, systemImage: "exclamationmark.triangle").foregroundStyle(.red); Button("Dismiss") { model.actionError = nil } }
        } else if let a = model.lastAction {
            toast {
                Text(a.title)
                if !a.records.isEmpty { Button("Undo") { model.undoLast() } }
                Button { model.lastAction = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).help("Dismiss")
            }
        }
    }

    private func toast(@ViewBuilder _ c: () -> some View) -> some View {
        HStack(spacing: Space.m, content: c)
            .padding(.horizontal, Space.l).padding(.vertical, Space.s)
            .background(.regularMaterial, in: Capsule())
            .shadow(radius: 4)
            .padding(Space.l)
    }
}
