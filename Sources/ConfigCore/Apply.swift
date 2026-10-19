import Foundation

/// One-click changes: run a fix right away and return the steps that undo it.
/// Fixes that can't be undone (uninstalls, updates, purges, installs with options) still go through the confirm sheet.
public enum Apply {
    public struct Outcome: Sendable {
        public var summary: String
        public var undo: [UndoStep] = []
        public var failed = false
    }

    /// True when the change can't be taken back, so it keeps its confirm sheet.
    public static func needsConfirm(_ fix: Fix) -> Bool {
        switch fix {
        case .cli(let args, _, _): inverse(args) == nil && !args.starts(with: ["mcp", "remove"])
        case .installSkills: true
        case .many(let fs): fs.contains(where: needsConfirm)
        case .bulk(let ss): ss.contains { $0.fix.map(needsConfirm) ?? false }
        default: false
        }
    }

    /// The command that reverses `args`, for the plugin commands that have one.
    static func inverse(_ args: [String]) -> [String]? {
        guard args.count >= 3, args[0] == "plugin" else { return nil }
        let rest = Array(args.dropFirst(2))
        switch args[1] {
        case "enable": return ["plugin", "disable"] + rest
        case "disable": return ["plugin", "enable"] + rest
        case "install": return ["plugin", "uninstall"] + rest.filter { !$0.hasPrefix("--config") } + ["--keep-data"]
        default: return nil
        }
    }

    public static func run(_ fix: Fix, home: URL = Paths.home) async -> Outcome {
        do { return try await runThrowing(fix, home: home) } catch { return Outcome(summary: error.localizedDescription, failed: true) }
    }

    static func runThrowing(_ fix: Fix, home: URL) async throws -> Outcome {
        let backups = ScopeMove.backups(home)
        switch fix {
        case .frontmatter(let file, let key, let value):
            let r = try Backup.snapshot(file, home: home)
            _ = try setFrontmatterKey(file, key: key, value: value, backupDir: backups)
            let name = file.lastPathComponent == "SKILL.md" ? file.deletingLastPathComponent().lastPathComponent : file.deletingPathExtension().lastPathComponent
            return Outcome(summary: "Updated \(name)", undo: [.restore(r)])
        case .settingsKey(let file, let path, let value):
            let old = ScopeMove.get(readJSON(file), path)
            try ScopeMove.setJSON(file, path, value, home: home)
            return Outcome(summary: value == nil ? "Removed \(path.joined(separator: "."))" : "Set \(path.joined(separator: "."))", undo: [.json(file: file, path: path, old: ScopeMove.encode(old))])
        case .removeHooks(let refs):
            var undo: [UndoStep] = []
            for (file, rs) in Dictionary(grouping: refs, by: \.file) {
                let old = ScopeMove.get(readJSON(file), ["hooks"])
                _ = try removeHooks(file, rs, backupDir: backups)
                undo.append(.json(file: file, path: ["hooks"], old: ScopeMove.encode(old)))
            }
            return Outcome(summary: refs.count == 1 ? "Removed 1 hook" : "Removed \(refs.count) hooks", undo: undo)
        case .removeLines(let file, let lines):
            let r = try Memory.removeLines(file, lines, home: home)
            return Outcome(summary: "Removed \(lines.count) line\(lines.count == 1 ? "" : "s") from \(file.lastPathComponent)", undo: [.restore(r)])
        case .trash(let urls):
            var undo: [UndoStep] = []
            for u in urls where trashRefusal(u) == nil && exists(u) {
                var out: NSURL?
                try FileManager.default.trashItem(at: u, resultingItemURL: &out)
                if let t = out as URL? { undo.append(.untrash(original: u, trashed: t)) }
            }
            return Outcome(summary: undo.count == 1 ? "Moved \(urls[0].lastPathComponent) to the Trash" : "Moved \(undo.count) items to the Trash", undo: undo)
        case .cli(let args, _, let cwd):
            var undo: [UndoStep] = []
            if args.starts(with: ["mcp", "remove"]), args.count >= 3 {
                // Keep the entry so Undo can write it back at key level (~/.claude.json changes too often to restore whole).
                let scope = args.firstIndex(of: "-s").map { args[$0 + 1] } ?? "local"
                let t: Target? = scope == "user" ? .user : cwd.map { scope == "project" ? .project($0) : .local($0) }
                if let t {
                    let (file, path) = ScopeMove.mcpLocation(t, home: home)
                    if let entry = ScopeMove.get(readJSON(file), path + [args[2]]) { undo.append(.json(file: file, path: path + [args[2]], old: ScopeMove.encode(entry))) }
                }
            } else if let back = inverse(args) {
                undo.append(.cli(args: back, cwd: cwd))
            }
            let r = await ClaudeCLI.run(args, in: cwd.map { URL(filePath: $0) })
            guard r.ok else { return Outcome(summary: r.output.isEmpty ? "claude \(args.prefix(2).joined(separator: " ")) failed" : r.output, failed: true) }
            return Outcome(summary: done(args), undo: undo)
        case .many(let fixes):
            var all = Outcome(summary: "")
            for f in fixes {
                let o = await run(f, home: home)
                all.undo += o.undo
                if o.failed { all.failed = true; all.summary = o.summary; return all }
                all.summary = all.summary.isEmpty ? o.summary : all.summary
            }
            return all
        case .bulk(let steps):
            var all = Outcome(summary: ""), ok = 0, failed = 0, skipped = 0
            for st in steps {
                guard let f = st.fix else { skipped += 1; continue }
                let o = await run(f, home: home)
                all.undo += o.undo
                if o.failed { failed += 1; all.failed = true } else { ok += 1 }
            }
            all.summary = "Changed \(ok)" + (failed > 0 ? ", \(failed) failed" : "") + (skipped > 0 ? ", \(skipped) skipped" : "")
            return all
        case .installSkills:
            return Outcome(summary: "Installs need the review sheet.", failed: true)
        }
    }

    static func done(_ args: [String]) -> String {
        let name = args.count > 2 ? args[2] : ""
        switch (args.first ?? "", args.count > 1 ? args[1] : "") {
        case ("plugin", "enable"): return "Turned on \(name)"
        case ("plugin", "disable"): return "Turned off \(name)"
        case ("plugin", "install"): return "Installed \(name)"
        case ("mcp", "remove"): return "Removed \(name)"
        default: return "Done"
        }
    }

    /// Undoes a change: newest step first. Stops at the first step that fails.
    public static func undo(_ steps: [UndoStep], home: URL = Paths.home) async throws {
        for s in steps.reversed() {
            if case .cli(let args, let cwd) = s {
                let r = await ClaudeCLI.run(args, in: cwd.map { URL(filePath: $0) })
                if !r.ok { throw ScopeMoveError.unsupported("Undo failed: claude \(args.joined(separator: " ")): \(r.output)") }
            } else {
                try ScopeMove.runFileUndo([s], home: home)
            }
        }
    }
}
