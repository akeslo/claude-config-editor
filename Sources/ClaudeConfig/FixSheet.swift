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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(pending.title).font(.title3.weight(.semibold))
            Text(pending.fix.summary).font(.system(.body, design: .monospaced)).textSelection(.enabled)
            Text(result == nil ? "Preview" : failed ? "Failed" : "Done").font(.headline)
                .foregroundStyle(failed ? .red : .primary)
            ScrollView {
                Text(result ?? (preview.isEmpty ? "Loading preview…" : preview))
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .background(.background.secondary, in: .rect(cornerRadius: 6))
            .frame(minHeight: 160, maxHeight: 360)
            if case .settingsKey = pending.fix, result == nil {
                Text("The file is backed up first, and the change is refused if Claude wrote the file after it was read.")
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
        .task { preview = await makePreview() }
    }

    private func makePreview() async -> String {
        switch pending.fix {
        case .cli(let args, let dryRun, let cwd):
            guard let dryRun else { return "Will run:\n  claude \(args.joined(separator: " "))\n\nThis command has no dry-run mode; nothing runs until you click Apply." }
            let r = await ClaudeCLI.run(dryRun, in: cwd.map { URL(filePath: $0) })
            return "Dry run (claude \(dryRun.joined(separator: " "))):\n\n" + r.output
        case .trash(let urls):
            return "These go to the Trash (recoverable from Finder):\n\n" + urls.map { "  \(shortPath($0))  \(formatBytes(exists($0) ? directorySize($0) : 0))" }.joined(separator: "\n")
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
            switch pending.fix {
            case .cli(let args, _, let cwd):
                let r = await ClaudeCLI.run(args, in: cwd.map { URL(filePath: $0) })
                failed = !r.ok
                result = r.output.isEmpty ? (r.ok ? "Finished." : "Exit code \(r.status)") : r.output
            case .trash(let urls):
                for url in urls where exists(url) { try FileManager.default.trashItem(at: url, resultingItemURL: nil) }
                result = "Moved \(urls.count) item(s) to the Trash."
            case .settingsKey(let file, let path, let value):
                let backup = try updateSettingsKey(file, path: path, value: value)
                result = "Saved." + (backup.map { "\nBackup: \(shortPath($0))" } ?? "")
            }
        } catch {
            failed = true
            result = error.localizedDescription
        }
        await model.refresh()
    }
}
