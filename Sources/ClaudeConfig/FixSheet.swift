import ConfigCore
import SwiftUI

/// Every change goes through here: show exactly what will happen, then run it on confirm.
struct FixSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let pending: PendingFix

    @State private var preview = ""
    @State private var result: String?
    @State private var failed = false
    @State private var running = false
    private var fix: Fix { pending.fix }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(pending.title).font(.title3.weight(.semibold))
            if case .cli(let args, _, _) = pending.fix, args.starts(with: ["plugin", "install"]), result == nil {
                Text("Plugin skills can't be set to 'only when I call it', so Claude may run them on its own. (Claude Code has no setting for this, and edits to plugin files are undone on update.)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(fix.summary).font(.system(.body, design: .monospaced)).textSelection(.enabled)
            Text(result == nil ? "Preview" : failed ? "Failed" : "Done").font(.headline)
                .foregroundStyle(failed ? Ink.danger : .primary)
            ScrollView {
                Text(result ?? (preview.isEmpty ? "Loading preview…" : preview))
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .background(.background.secondary, in: .rect(cornerRadius: 6))
            .frame(minHeight: 160, maxHeight: 360)
            if case .cli(let args, _, _) = pending.fix, args.first == "purge", result == nil {
                Text("Purge permanently deletes this project's transcripts, auto memory, history lines and its trust and allowed-tool approvals. It is not backed up and cannot be undone. Claude will ask to trust the folder again.")
                    .font(.callout).foregroundStyle(Ink.danger)
            }
            if pending.fix.editsSettings, result == nil {
                Text("The file is backed up to ~/.claude/config-editor-backups/<tool> first, and the change is refused if Claude wrote the file after it was read.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                if result == nil {
                    Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Apply") { Task { await apply() } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(running || preview.isEmpty)
                } else {
                    Button("Close") { dismiss() }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 620)
        .task { preview = await makePreview(fix) }
    }

    private func makePreview(_ fix: Fix) async -> String {
        switch fix {
        case .many(let fixes):
            var parts: [String] = []
            for f in fixes { parts.append(await makePreview(f)) }
            return parts.joined(separator: "\n\n")
        case .bulk(let steps):
            var parts: [String] = []
            for st in steps {
                guard let f = st.fix else { parts.append("• \(st.label)\n  SKIPPED: \(st.skip ?? "")"); continue }
                parts.append("• \(st.label)\n" + (await makePreview(f)).split(separator: "\n", omittingEmptySubsequences: false).map { "  " + $0 }.joined(separator: "\n"))
            }
            return parts.joined(separator: "\n\n")
        case .frontmatter(let file, let key, let value):
            let before = (readText(file) ?? "").split(separator: "\n").first { $0.hasPrefix(key + ":") }.map(String.init) ?? "(not set)"
            return "File:   \(shortPath(file))\nBefore: \(before)\nAfter:  \(value.map { "\(key): \($0)" } ?? "(removed)")"
        case .removeLines(let file, let lines, _):
            let all = (readText(file) ?? "").split(separator: "\n", omittingEmptySubsequences: false)
            return "File: \(shortPath(file)) (backed up first)\nRemoves these lines:\n\n" + lines.filter { $0 < all.count }.map { "  \($0 + 1): " + all[$0] }.joined(separator: "\n")
        case .cli(let args, let dryRun, let cwd):
            guard let dryRun else {
                return "Will run:\n  claude \(args.joined(separator: " "))\n\nThis command has no dry-run mode; nothing runs until you click Apply."
                    + (args.starts(with: ["plugin", "marketplace", "add"]) ? "\n\nThen install its plugins from the Plugins tab." : "")
            }
            let r = await ClaudeCLI.run(dryRun, in: cwd.map { URL(filePath: $0) })
            return "Dry run (claude \(dryRun.joined(separator: " "))):\n\n" + r.output
        case .trash(let urls):
            return "These go to the Trash (recoverable from Finder):\n\n" + urls.map { "  \(shortPath($0))  " + (trashRefusal($0).map { "SKIPPED (\($0))" } ?? formatBytes(exists($0) ? directorySize($0) : 0)) }.joined(separator: "\n")
        case .removeHooks(let refs):
            return "Will remove from settings:\n" + refs.map { "  \($0.event): \($0.command)\n    in \(shortPath($0.file))" }.joined(separator: "\n")
        case .settingsKey(let file, let path, let value):
            var node: Any? = readJSON(file)
            for key in path { node = (node as? JSON)?[key] }
            let before = node.map { "\($0)" } ?? "(not set)"
            return "File:   \(shortPath(file))\nKey:    \(path.joined(separator: " → "))\nBefore: \(before)\nAfter:  \(value ?? "(removed)")"
        }
    }

    private func apply() async {
        running = true
        defer { running = false }
        do {
            result = try await run(fix)
        } catch {
            failed = true
            result = error.localizedDescription
        }
        await model.refresh()
    }

    /// Runs one fix and describes what happened; a failed step stops the rest.
    private func run(_ fix: Fix) async throws -> String {
        var result = ""
        switch fix {
        case .many(let fixes):
            var lines: [String] = []
            // Report the steps that already ran when a later one fails, so a partial apply isn't hidden.
            for f in fixes where !failed {
                do { lines.append(try await run(f)) } catch { failed = true; lines.append("Stopped: \(error.localizedDescription)") }
            }
            result = lines.joined(separator: "\n")
        case .bulk(let steps):
            // Each item runs on its own: a failure is recorded and the rest still go.
            var rows: [(label: String, outcome: BulkOutcome)] = []
            for st in steps {
                guard let f = st.fix else { rows.append((st.label, .skipped(st.skip ?? "nothing to change"))); continue }
                failed = false
                do {
                    let out = try await run(f).split(whereSeparator: \.isNewline).joined(separator: " ")
                    rows.append((st.label, failed ? .failed(out) : .done(out)))
                } catch { rows.append((st.label, .failed(error.localizedDescription))) }
            }
            failed = rows.contains { if case .failed = $0.outcome { true } else { false } }
            result = bulkReport(rows)
        case .frontmatter(let file, let key, let value):
            let backup = try setFrontmatterKey(file, key: key, value: value)
            result = "Saved \(shortPath(file))." + (backup.map { " Backup: \(shortPath($0))" } ?? "")
        case .removeLines(let file, let lines, let modified):
            let b = try Memory.removeLines(at: lines, in: file, expectedModified: modified)
            result = "Removed \(lines.count) line(s) from \(shortPath(file))." + (b.map { " Backup: \(shortPath($0.copy))" } ?? "")
        case .cli(let args, _, let cwd):
            let r = await ClaudeCLI.run(args, in: cwd.map { URL(filePath: $0) })
            if !r.ok { failed = true }
            result = r.output.isEmpty ? (r.ok ? "Finished." : "Exit code \(r.status)") : r.output
        case .trash(let urls):
            let allowed = urls.filter { trashRefusal($0) == nil }
            for url in allowed where exists(url) { try FileManager.default.trashItem(at: url, resultingItemURL: nil) }
            result = "Moved \(allowed.count) item(s) to the Trash." + (allowed.count < urls.count ? " Skipped \(urls.count - allowed.count) protected item(s)." : "")
        case .removeHooks(let refs):
            var backups: [URL] = []
            for (file, rs) in Dictionary(grouping: refs, by: \.file) { if let b = try removeHooks(file, rs) { backups.append(b) } }
            result = "Removed \(refs.count) hook(s)." + backups.map { "\nBackup: \(shortPath($0))" }.joined()
        case .settingsKey(let file, let path, let value):
            let backup = try updateSettingsKey(file, path: path, value: value)
            result = "Saved." + (backup.map { "\nBackup: \(shortPath($0))" } ?? "")
        }
        return result
    }
}
