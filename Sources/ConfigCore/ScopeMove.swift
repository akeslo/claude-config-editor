import Foundation

/// Where an item applies. Managed items are shown read-only and are never a move target.
public enum Target: Hashable, Sendable {
    case user, project(String), local(String)

    /// The CLI's `--scope` value.
    public var cliScope: String { switch self { case .user: "user"; case .project: "project"; case .local: "local" } }
    public var folder: String? { switch self { case .user: nil; case .project(let p), .local(let p): p } }
    public var short: String { switch self { case .user: "User"; case .project: "Project"; case .local: "Local" } }
    public var label: String {
        let name = folder.map { ($0 as NSString).lastPathComponent } ?? ""
        switch self {
        case .user: return "User: all projects"
        case .project: return "Project: \(name), shared in .claude/"
        case .local: return "Local: \(name) only, not shared"
        }
    }
}

/// One step that undoes part of a change. Undo runs the steps in reverse.
public enum UndoStep: Sendable {
    /// Move a file or folder back where it was.
    case moveBack(from: URL, to: URL)
    /// Put one JSON key back to its old value (JSON-encoded inside a one-item array; nil removes the key).
    case json(file: URL, path: [String], old: Data?)
    /// Put a file back from the Trash.
    case untrash(original: URL, trashed: URL)
    /// Restore a backed-up copy.
    case restore(Backup.Record)
    /// Run a claude command.
    case cli(args: [String], cwd: String?)
}

public enum ScopeMoveError: LocalizedError, Equatable {
    case exists(String), unsupported(String), notFound(String)
    public var errorDescription: String? {
        switch self {
        case .exists(let p): "\(p) already exists there. Rename or remove it first."
        case .unsupported(let why): why
        case .notFound(let what): "Couldn't find \(what). Rescan and try again."
        }
    }
}

/// Moves items between User, Project and Local scope. Every write keeps a backup; every move returns its undo steps.
public enum ScopeMove {
    static func claudeJSON(_ home: URL) -> URL { home.appending(path: ".claude.json") }

    // MARK: Where things live

    /// The scope a settings, hook or permission file belongs to; nil for managed, plugin and ~/.claude.json files.
    public static func target(ofSettings url: URL, home: URL = Paths.home) -> Target? {
        let p = url.standardizedFileURL.path, claude = home.appending(path: ".claude").standardizedFileURL.path
        if p == claude + "/settings.json" || p == claude + "/settings.local.json" { return .user }
        let dir = url.deletingLastPathComponent()
        guard dir.lastPathComponent == ".claude" else { return nil }
        let project = dir.deletingLastPathComponent().standardizedFileURL.path
        return url.lastPathComponent == "settings.json" ? .project(project) : url.lastPathComponent == "settings.local.json" ? .local(project) : nil
    }

    public static func settingsFile(_ t: Target, home: URL = Paths.home) -> URL {
        switch t {
        case .user: home.appending(path: ".claude/settings.json")
        case .project(let p): URL(filePath: p).appending(path: ".claude/settings.json")
        case .local(let p): URL(filePath: p).appending(path: ".claude/settings.local.json")
        }
    }

    public static func target(of c: Component) -> Target? {
        switch c.scope {
        case .user: .user
        case .project: c.owner.map { .project($0) }
        default: nil
        }
    }

    /// Skills, agents, commands and output styles have no local-only folder in Claude Code.
    public static func componentDestination(_ c: Component, to t: Target, home: URL = Paths.home) -> URL? {
        let base: URL
        switch t {
        case .user: base = home.appending(path: ".claude")
        case .project(let p): base = URL(filePath: p).appending(path: ".claude")
        case .local: return nil
        }
        let folder = switch c.kind { case .skill: "skills"; case .subagent: "agents"; case .command: "commands"; case .outputStyle: "output-styles" }
        return base.appending(path: folder).appending(path: trashURL(c).lastPathComponent)
    }

    public static func target(of f: InstructionFile, home: URL = Paths.home) -> Target? {
        switch f.kind {
        case .memoryIndex: return nil
        case .localMD: return f.project.map { .local($0) }
        case .claudeMD, .rule: return f.project.map { .project($0) } ?? (f.url.path.hasPrefix(home.appending(path: ".claude").path + "/") ? .user : nil)
        }
    }

    /// CLAUDE.md ↔ CLAUDE.local.md ↔ ~/.claude/CLAUDE.md; rules move between rules/ folders (no local rules folder).
    public static func instructionDestination(_ f: InstructionFile, to t: Target, home: URL = Paths.home) -> URL? {
        switch (f.kind, t) {
        case (.memoryIndex, _): return nil
        case (.rule, .user): return home.appending(path: ".claude/rules/\(f.url.lastPathComponent)")
        case (.rule, .project(let p)): return URL(filePath: p).appending(path: ".claude/rules/\(f.url.lastPathComponent)")
        case (.rule, .local): return nil
        case (_, .user): return home.appending(path: ".claude/CLAUDE.md")
        case (_, .project(let p)): return URL(filePath: p).appending(path: "CLAUDE.md")
        case (_, .local(let p)): return URL(filePath: p).appending(path: "CLAUDE.local.md")
        }
    }

    /// Where an MCP server entry lives: ~/.claude.json (user, local) or <project>/.mcp.json.
    public static func mcpLocation(_ t: Target, home: URL = Paths.home) -> (file: URL, path: [String]) {
        switch t {
        case .user: (claudeJSON(home), ["mcpServers"])
        case .local(let p): (claudeJSON(home), ["projects", p, "mcpServers"])
        case .project(let p): (URL(filePath: p).appending(path: ".mcp.json"), ["mcpServers"])
        }
    }

    public static func target(of m: MCPServer) -> Target? {
        switch m.scope {
        case .user: .user
        case .local: m.project.map { .local($0) }
        case .project: m.project.map { .project($0) }
        default: nil
        }
    }

    public static func target(ofPlugin p: Plugin) -> Target? {
        switch p.scope {
        case "user": .user
        case "project": p.projectPath.map { .project($0) }
        case "local": p.projectPath.map { .local($0) }
        default: nil
        }
    }

    // MARK: Moves

    /// Moves a file or folder; refuses to overwrite. A copy is backed up first and kept.
    public static func moveFile(_ src: URL, to dst: URL, home: URL = Paths.home) throws -> [UndoStep] {
        let fm = FileManager.default
        guard exists(src) else { throw ScopeMoveError.notFound(src.lastPathComponent) }
        if src.standardizedFileURL == dst.standardizedFileURL { return [] }
        if exists(dst) { throw ScopeMoveError.exists(shortPath(dst)) }
        do { try Backup.snapshot(src, home: home) } catch { throw WriteError.backupFailed(src) }
        try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: src, to: dst)
        return [.moveBack(from: dst, to: src)]
    }

    public static func move(component c: Component, to t: Target, home: URL = Paths.home) throws -> [UndoStep] {
        guard target(of: c) != nil else { throw ScopeMoveError.unsupported("\(c.name) comes from \(c.scope.rawValue) and can't be moved here.") }
        guard let dst = componentDestination(c, to: t, home: home) else {
            throw ScopeMoveError.unsupported("Claude Code has no local-only folder for \(c.kind.rawValue.lowercased())s. Choose User or Project.")
        }
        return try moveFile(trashURL(c), to: dst, home: home)
    }

    public static func move(instruction f: InstructionFile, to t: Target, home: URL = Paths.home) throws -> [UndoStep] {
        guard target(of: f, home: home) != nil, let dst = instructionDestination(f, to: t, home: home) else {
            throw ScopeMoveError.unsupported("\(f.url.lastPathComponent) can't move to \(t.short).")
        }
        return try moveFile(f.url, to: dst, home: home)
    }

    public static func move(rule r: PermissionRule, to t: Target, home: URL = Paths.home) throws -> [UndoStep] {
        guard target(ofSettings: r.sourceURL, home: home) != nil else { throw ScopeMoveError.unsupported("This rule is managed or stored in ~/.claude.json, so it can't be moved.") }
        let dst = settingsFile(t, home: home), path = ["permissions", r.kind]
        if dst.standardizedFileURL == r.sourceURL.standardizedFileURL { return [] }
        return try editJSON([
            (dst, path, { old in var a = old as? [String] ?? []; if !a.contains(r.rule) { a.append(r.rule) }; return a }),
            (r.sourceURL, path, { old in let a = (old as? [String] ?? []).filter { $0 != r.rule }; return a.isEmpty ? nil : a }),
        ], home: home)
    }

    public static func move(hook h: Hook, to t: Target, home: URL = Paths.home) throws -> [UndoStep] {
        guard target(ofSettings: h.sourceURL, home: home) != nil else { throw ScopeMoveError.unsupported("Plugin and managed hooks can't be moved.") }
        let dst = settingsFile(t, home: home)
        if dst.standardizedFileURL == h.sourceURL.standardizedFileURL { return [] }
        func cmd(_ e: JSON) -> String { e["command"] as? String ?? e["url"] as? String ?? e["prompt"] as? String ?? "" }
        let groups = (readJSON(h.sourceURL)?["hooks"] as? JSON)?[h.event] as? [JSON] ?? []
        guard let entry = groups.first(where: { ($0["matcher"] as? String) == h.matcher })?["hooks"].flatMap({ ($0 as? [JSON])?.first { cmd($0) == h.command } }) else {
            throw ScopeMoveError.notFound("the \(h.event) hook")
        }
        let path = ["hooks", h.event]
        return try editJSON([
            (dst, path, { old in
                var gs = old as? [JSON] ?? []
                if let i = gs.firstIndex(where: { ($0["matcher"] as? String) == h.matcher }) {
                    var hs = gs[i]["hooks"] as? [JSON] ?? []
                    if !hs.contains(where: { cmd($0) == h.command }) { hs.append(entry) }
                    gs[i]["hooks"] = hs
                } else {
                    var g: JSON = ["hooks": [entry]]
                    if let m = h.matcher { g["matcher"] = m }
                    gs.append(g)
                }
                return gs
            }),
            (h.sourceURL, path, { old in
                let gs: [JSON] = (old as? [JSON] ?? []).compactMap { g in
                    guard (g["matcher"] as? String) == h.matcher else { return g }
                    var g = g
                    let hs = (g["hooks"] as? [JSON] ?? []).filter { cmd($0) != h.command }
                    if hs.isEmpty { return nil }
                    g["hooks"] = hs
                    return g
                }
                return gs.isEmpty ? nil : gs
            }),
        ], home: home)
    }

    /// Moves one top-level settings key; refuses when the destination already sets it differently.
    public static func move(settingKey key: String, from src: URL, to t: Target, home: URL = Paths.home) throws -> [UndoStep] {
        let dst = settingsFile(t, home: home)
        if dst.standardizedFileURL == src.standardizedFileURL { return [] }
        guard let value = readJSON(src)?[key] else { throw ScopeMoveError.notFound(key) }
        if let there = readJSON(dst)?[key], !jsonEqual(there, value) { throw ScopeMoveError.exists("\(key) in \(shortPath(dst))") }
        return try editJSON([(dst, [key], { _ in value }), (src, [key], { _ in nil })], home: home)
    }

    public static func move(mcp m: MCPServer, to t: Target, home: URL = Paths.home) throws -> [UndoStep] {
        guard let from = target(of: m) else { throw ScopeMoveError.unsupported("\(m.name) comes from \(m.scope.rawValue) and can't be moved here.") }
        if from == t { return [] }
        let (sf, sp) = mcpLocation(from, home: home), (df, dp) = mcpLocation(t, home: home)
        guard let entry = get(readJSON(sf), sp + [m.name]) else { throw ScopeMoveError.notFound(m.name) }
        if get(readJSON(df), dp + [m.name]) != nil { throw ScopeMoveError.exists("\(m.name) in \(t.short)") }
        return try editJSON([(df, dp + [m.name], { _ in entry }), (sf, sp + [m.name], { _ in nil })], home: home)
    }

    /// Install at the new scope, then uninstall the old one keeping its data. Undo runs the reverse.
    public static func pluginMove(_ p: Plugin, to t: Target) -> (steps: [(args: [String], cwd: String?)], undo: [UndoStep])? {
        guard let from = target(ofPlugin: p), from != t else { return nil }
        func install(_ x: Target) -> (args: [String], cwd: String?) { (["plugin", "install", p.id, "--scope", x.cliScope], x.folder) }
        func uninstall(_ x: Target) -> (args: [String], cwd: String?) { (["plugin", "uninstall", p.id, "--scope", x.cliScope, "--keep-data"], x.folder) }
        func disable(_ x: Target) -> (args: [String], cwd: String?) { (["plugin", "disable", p.id, "--scope", x.cliScope], x.folder) }
        var steps = [install(t)]
        if !p.enabled { steps.append(disable(t)) }
        steps.append(uninstall(from))
        var back = [install(from)]
        if !p.enabled { back.append(disable(from)) }
        back.append(uninstall(t))
        // Undo runs steps in reverse, so store them reversed.
        return (steps, back.reversed().map { .cli(args: $0.args, cwd: $0.cwd) })
    }

    // MARK: JSON key edits

    static func get(_ root: Any?, _ path: [String]) -> Any? {
        path.reduce(root) { ($0 as? JSON)?[$1] }
    }

    static func set(_ dict: inout JSON, _ path: ArraySlice<String>, _ value: Any?) {
        guard let key = path.first else { return }
        if path.count == 1 { dict[key] = value; return }
        var child = dict[key] as? JSON ?? [:]
        set(&child, path.dropFirst(), value)
        // A removal that empties its parent drops the parent too ("hooks": {} would linger otherwise).
        dict[key] = value == nil && child.isEmpty ? nil : child
    }

    static func encode(_ v: Any?) -> Data? { v.flatMap { try? JSONSerialization.data(withJSONObject: [$0]) } }
    static func decode(_ d: Data?) -> Any? { d.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [Any] }?.first }
    static func jsonEqual(_ a: Any, _ b: Any) -> Bool { encode(a) == encode(b) }

    /// Sets one key path, keeping every other key; refuses if the file changed since it was read. Backs up first.
    public static func setJSON(_ url: URL, _ path: [String], _ value: Any?, home: URL = Paths.home) throws {
        try ConfigWriter.mutateJSON(url, home: home, expectedModified: modificationDate(url)) { set(&$0, path[...], value) }
    }

    /// Applies key edits in order as one change: if one fails, the ones already made are put back.
    public static func editJSON(_ edits: [(URL, [String], (Any?) -> Any?)], home: URL = Paths.home) throws -> [UndoStep] {
        var undo: [UndoStep] = []
        do {
            for (url, path, f) in edits {
                let old = get(readJSON(url), path)
                try setJSON(url, path, f(old), home: home)
                undo.append(.json(file: url, path: path, old: encode(old)))
            }
        } catch {
            try? runFileUndo(undo, home: home)
            throw error
        }
        return undo
    }

    /// Undoes file and JSON steps (newest first). CLI steps are run by `Apply.undo`.
    public static func runFileUndo(_ steps: [UndoStep], home: URL = Paths.home) throws {
        for s in steps.reversed() {
            switch s {
            case .moveBack(let from, let to):
                if exists(to) { throw ScopeMoveError.exists(shortPath(to)) }
                try FileManager.default.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: from, to: to)
            case .json(let file, let path, let old): try setJSON(file, path, decode(old), home: home)
            case .untrash(let original, let trashed): try FileManager.default.moveItem(at: trashed, to: original)
            case .restore(let r): try Backup.restore(r)
            case .cli: break
            }
        }
    }
}
