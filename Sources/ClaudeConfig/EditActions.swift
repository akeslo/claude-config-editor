import ConfigCore
import SwiftUI

// Reusable edit/reset/delete pieces. All deletes and writes go through `Backup`, so the undo toast can put things back.

extension AppModel {
    /// Records an undoable action and rescans so every page sees the change.
    func didAct(_ title: String, _ records: [Backup.Record]) {
        act(title, records.map(UndoStep.restore))
        Task { await refresh() }
    }

    /// Shows the toast for a finished change; empty `undo` shows it without an Undo button.
    func act(_ title: String, _ undo: [UndoStep]) {
        lastAction = (title, undo)
        actionError = nil
    }

    /// Backs up and removes each URL; stops at the first failure (earlier ones stay undoable).
    func trashWithUndo(_ urls: [URL], title: String) {
        var done: [Backup.Record] = []
        do { for u in urls { done.append(try Backup.trash(u)) } } catch { actionError = error.localizedDescription }
        if !done.isEmpty { didAct(title, done) }
    }

    func undoLast() {
        guard let a = lastAction else { return }
        lastAction = nil
        Task {
            do { try await Apply.undo(a.undo); act("Undone", []) } catch { actionError = error.localizedDescription }
            await refresh()
        }
    }
}

/// "Delete": one click. Items go to ~/.claude/config-editor-backups/undo first, so the toast can undo it.
struct ConfirmDeleteButton: View {
    @Environment(AppModel.self) private var model
    let urls: [URL]
    var label = "Delete"

    init(url: URL, label: String = "Delete") { urls = [url]; self.label = label }
    init(urls: [URL], label: String = "Delete") { self.urls = urls; self.label = label }

    var body: some View {
        let ok = urls.filter { trashRefusal($0) == nil }
        if !ok.isEmpty {
            Button(label.replacingOccurrences(of: "…", with: ""), role: .destructive) {
                model.trashWithUndo(ok, title: "Deleted \(ok.count == 1 ? ok[0].lastPathComponent : "\(ok.count) items")")
            }
            .help("A backup is kept in ~/.claude/config-editor-backups/undo; undo from the message that appears")
        }
    }
}

/// "Reset": one click. `perform` does the reset and may return a backup record for undo.
struct ResetButton: View {
    @Environment(AppModel.self) private var model
    let what: String
    var explanation = "This falls back to the default."
    let perform: () throws -> Backup.Record?

    var body: some View {
        Button("Reset") {
            do { model.didAct("Reset \(what)", try perform().map { [$0] } ?? []) } catch { model.actionError = error.localizedDescription }
        }
        .help(explanation + " A backup is kept so you can undo.")
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
        VStack(alignment: .leading, spacing: PSpace.s2) {
            Text(url.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
            TextEditor(text: $text).font(.system(.body, design: .monospaced)).frame(minWidth: 640, minHeight: 420)
            if let error { Text(error).foregroundStyle(PColor.danger.fg).font(.callout) }
            HStack {
                Text(formatTokens(estimateTokens(text))).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }.keyboardShortcut("s").disabled(text == original)
            }
        }
        .padding(PSpace.s4)
        .onAppear {
            original = readText(url) ?? ""
            text = original
            loadedAt = modificationDate(url)
        }
    }

    private func save() {
        do {
            if exists(url), modificationDate(url) != loadedAt { throw WriteError.changedOnDisk(url) }
            let now = Date()
            let record = try ConfigWriter.writeText(text, to: url, home: Paths.home, expectedModified: loadedAt)
                .map { Backup.Record(original: url, copy: $0, date: now, removed: false) }
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
                .foregroundStyle(level == .stale ? PColor.attention.fg : .secondary)
                .help(reason)
        }
    }
}

/// Bottom toast with Undo for the last action, or the last error. Attached once in RootView; hides itself after 8 seconds.
struct UndoToast: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if let err = model.actionError {
                toast {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(PColor.attention.fg)
                    Text(err).lineLimit(2)
                    Button("Dismiss") { model.actionError = nil }
                }
            } else if let a = model.lastAction {
                toast {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(PColor.success.fg)
                    Text(a.title).lineLimit(1)
                    if !a.undo.isEmpty { Button("Undo") { model.undoLast() }}
                    Button { model.lastAction = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).help("Dismiss").accessibilityLabel("Dismiss")
                }
                .task(id: a.title) { try? await Task.sleep(for: .seconds(8)); if model.lastAction?.title == a.title { model.lastAction = nil } }
            }
        }
        .animation(.snappy, value: model.lastAction?.title)
        .animation(.snappy, value: model.actionError)
    }

    private func toast(@ViewBuilder _ c: () -> some View) -> some View {
        HStack(spacing: PSpace.s3, content: c)
            .font(.callout)
            .padding(.horizontal, PSpace.s4).padding(.vertical, PSpace.s2)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.separator, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
            .padding(PSpace.s4)
            .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
