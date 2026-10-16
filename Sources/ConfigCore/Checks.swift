import Foundation

public enum AppSection: String, CaseIterable, Identifiable, Sendable {
    case health = "Health", context = "Context Budget", analytics = "Analytics", storage = "Storage", projects = "Projects & History"
    case permissions = "Permissions", mcp = "MCP Servers", skills = "Skills & Agents", plugins = "Plugins"
    case hooks = "Hooks", instructions = "Instructions & Memory", settings = "Settings", discover = "Discover"
    public var id: String { rawValue }

    public var symbol: String {
        switch self {
        case .health: "stethoscope"
        case .context: "gauge.with.dots.needle.50percent"
        case .analytics: "chart.bar.xaxis"
        case .storage: "internaldrive"
        case .projects: "folder"
        case .permissions: "lock.shield"
        case .mcp: "server.rack"
        case .skills: "wand.and.stars"
        case .plugins: "puzzlepiece.extension"
        case .hooks: "arrow.triangle.branch"
        case .instructions: "doc.text"
        case .settings: "gearshape"
        case .discover: "sparkle.magnifyingglass"
        }
    }

    public var term: Term {
        switch self {
        case .health, .context: .contextWindow
        case .storage: .scratch
        case .analytics: .transcripts
        case .projects: .project
        case .permissions: .permissions
        case .mcp: .mcpServer
        case .skills: .skill
        case .plugins, .discover: .plugin
        case .hooks: .hook
        case .instructions: .claudeMD
        case .settings: .settings
        }
    }
}

/// A change the app can make. Every fix is previewed before it runs.
public enum Fix: Sendable {
    /// Runs `claude <args>`; when `dryRun` is set, its output is the preview.
    case cli(args: [String], dryRun: [String]?, cwd: String?)
    /// Moves files to the Trash.
    case trash([URL])
    /// Sets (or removes, when nil) one key in a settings file.
    case settingsKey(file: URL, path: [String], value: String?)

    public var summary: String {
        switch self {
        case .cli(let args, _, _): "claude " + args.map { $0.contains(" ") ? "\"\($0)\"" : $0 }.joined(separator: " ")
        case .trash(let urls): "Move \(urls.count) item\(urls.count == 1 ? "" : "s") to the Trash"
        case .settingsKey(let file, let path, let value): "Set \(path.joined(separator: ".")) = \(value.map { "\"\($0)\"" } ?? "(removed)") in \(file.path.replacingOccurrences(of: Paths.home.path, with: "~"))"
        }
    }
}

public struct Issue: Identifiable, Sendable {
    public enum Severity: Int, Comparable, Sendable {
        case info = 0, warning = 1, problem = 2
        public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    }
    public var id: String { "\(section.rawValue)|\(title)|\(subject)|\(detail)" }
    public let severity: Severity
    public let section: AppSection
    public let title: String
    public let subject: String
    public let detail: String
    public let term: Term
    public var fix: Fix?
    public var file: URL?
    /// Rough cost so the list can rank by impact: tokens per session, or bytes on disk.
    public var tokens = 0
    public var bytes: Int64 = 0
}

public enum Checks {
    public static let loopbackHosts = ["localhost", "127.0.0.1", "[::1]", "0.0.0.0"]

    public static func run(_ s: Snapshot, storage: [StorageArea]) -> [Issue] {
        var out: [Issue] = []
        out += instructionChecks(s)
        out += skillChecks(s)
        out += mcpChecks(s)
        out += pluginChecks(s)
        out += hookChecks(s)
        out += permissionChecks(s)
        out += projectChecks(s)
        out += storageChecks(s, storage)
        out += settingsChecks(s)
        return out.sorted {
            ($0.severity, $0.tokens, $0.bytes) > ($1.severity, $1.tokens, $1.bytes)
        }
    }

    static func instructionChecks(_ s: Snapshot) -> [Issue] {
        s.instructions.flatMap { f in
            f.problems.map { p in
                Issue(severity: f.kind == .localMD ? .warning : .warning, section: .instructions,
                      title: "\(f.kind.rawValue): \(p)", subject: shortPath(f.url), detail: p,
                      term: f.kind == .memoryIndex ? .autoMemory : f.kind == .localMD ? .claudeLocalMD : .claudeMD,
                      file: f.url, tokens: f.tokens)
            }
        }
    }

    static func skillChecks(_ s: Snapshot) -> [Issue] {
        var out: [Issue] = []
        let skills = s.components.filter { $0.kind == .skill }
        let listing = skills.reduce(0) { $0 + $1.listingTokens }
        // shortcut: assumes a 200k context (1% ≈ 2,000 tokens); 1M-context models get 5x more room.
        if listing > 2_000 {
            out.append(Issue(severity: .warning, section: .skills, title: "Skill descriptions exceed the listing budget",
                             subject: "\(skills.count) skills",
                             detail: "Skill descriptions total \(formatTokens(listing)). The listing gets about 1% of the context window (≈2k tokens at 200k), so the least-used skills lose their description and Claude may not pick them. Hide unused ones below.",
                             term: .skillListing, tokens: listing))
        }
        for c in s.components where c.kind == .skill && c.listingTokens > 0 && c.usageCount == 0 && c.scope != .plugin {
            out.append(Issue(severity: .info, section: .skills, title: "Never-used skill is always listed", subject: c.name,
                             detail: "\(c.name) has never been used but its description costs \(formatTokens(c.listingTokens)) every session. Making it user-invocable-only keeps /\(c.name) working by hand.",
                             term: .skill, fix: .settingsKey(file: Paths.userSettings, path: ["skillOverrides", c.name], value: "user-invocable-only"),
                             file: c.file, tokens: c.listingTokens))
        }
        for c in s.components where c.kind == .skill {
            if c.lineCount > 500 {
                out.append(Issue(severity: .info, section: .skills, title: "SKILL.md over 500 lines", subject: c.name,
                                 detail: "\(c.lineCount) lines load every time the skill runs. Move reference material into linked files.", term: .skill, file: c.file))
            }
            if c.description.count > 1_536 {
                out.append(Issue(severity: .warning, section: .skills, title: "Description is cut off", subject: c.name,
                                 detail: "description + when_to_use is \(c.description.count) characters; Claude truncates at 1,536.", term: .skillListing, file: c.file))
            }
        }
        let byName = Dictionary(grouping: s.components.filter { $0.kind == .skill || $0.kind == .command }, by: \.name)
        for (name, items) in byName where items.count > 1 {
            out.append(Issue(severity: .warning, section: .skills, title: "Same name defined more than once", subject: name,
                             detail: "/\(name) exists in: " + items.map { "\($0.kind.rawValue) (\($0.scope.rawValue))" }.joined(separator: ", ") + ". Only one runs; skills beat commands, and personal beats project.",
                             term: .command, file: items.first?.file))
        }
        return out
    }

    static func mcpChecks(_ s: Snapshot) -> [Issue] {
        var out: [Issue] = []
        let claude = s.mcpServers.filter { $0.scope != .desktop }
        for (name, items) in Dictionary(grouping: claude, by: \.name) where Set(items.map(\.scope)).count > 1 || items.count > 1 && items.contains(where: { $0.scope == .user }) {
            out.append(Issue(severity: .warning, section: .mcp, title: "MCP server defined in several scopes", subject: name,
                             detail: "\(name) is defined in: " + items.map { "\($0.scope.rawValue)\($0.project.map { " (\(($0 as NSString).lastPathComponent))" } ?? "")" }.joined(separator: ", ") + ". The most specific scope wins and replaces the whole entry, so edits to the others have no effect there.",
                             term: .mcpScope))
        }
        for m in s.mcpServers {
            if let url = URL(string: m.command.split(separator: " ").first.map(String.init) ?? ""),
               ["http", "ws"].contains(url.scheme ?? ""), let host = url.host, !loopbackHosts.contains(host) {
                out.append(Issue(severity: .problem, section: .mcp, title: "MCP server uses an unencrypted connection", subject: "\(m.name) · \(shortPath(m.source))",
                                 detail: "\(url.absoluteString) is plain \(url.scheme!) to a remote host. Use https/wss.", term: .mcpServer, file: m.source))
            }
            let literal = (m.env.merging(m.headers) { a, _ in a }).filter { k, v in
                looksSecret(k) && !v.isEmpty && !v.contains("${") && !v.hasPrefix("$") && !v.hasPrefix("/") && !v.hasPrefix("~")
            }
            if !literal.isEmpty {
                out.append(Issue(severity: .problem, section: .mcp, title: "Secret written directly into MCP config", subject: "\(m.name) · \(shortPath(m.source))",
                                 detail: "\(literal.keys.sorted().joined(separator: ", ")) hold literal values in \(shortPath(m.source)). Use ${VAR} references so the secret stays out of config files and backups.",
                                 term: .env, file: m.source))
            }
        }
        return out
    }

    static func pluginChecks(_ s: Snapshot) -> [Issue] {
        var out: [Issue] = []
        let installed = Set(s.plugins.map(\.id))
        for src in s.settings {
            for (id, on) in src.root["enabledPlugins"] as? [String: Bool] ?? [:] where on && !installed.contains(id) {
                out.append(Issue(severity: .warning, section: .plugins, title: "Enabled plugin is not installed", subject: id,
                                 detail: "\(shortPath(src.url)) enables \(id), but it is not installed, so nothing loads.",
                                 term: .plugin, fix: .settingsKey(file: src.url, path: ["enabledPlugins", id], value: nil), file: src.url))
            }
        }
        for d in s.duplicatePlugins {
            out.append(Issue(severity: .info, section: .plugins, title: "Plugin installed more than once", subject: d.id,
                             detail: "\(d.id) also has a \(d.scope)-scope install (version \(d.version)) at \(shortPath(d.installPath)). Different projects may load different versions.",
                             term: .plugin, file: d.installPath))
        }
        for p in s.plugins {
            if p.enabled && p.usageCount == 0 {
                out.append(Issue(severity: .info, section: .plugins, title: "Enabled plugin never used", subject: p.id,
                                 detail: "\(p.id) is enabled but has no recorded use. Disabling it removes its always-on context cost and keeps the files.",
                                 term: .plugin, fix: .cli(args: ["plugin", "disable", p.id], dryRun: nil, cwd: nil), tokens: p.alwaysOnTokens ?? 0))
            }
            if !p.enabled {
                out.append(Issue(severity: .info, section: .plugins, title: "Disabled plugin still installed", subject: p.id,
                                 detail: "\(p.id) costs no context but keeps its files on disk. Uninstall it if you no longer need it.",
                                 term: .plugin, fix: .cli(args: ["plugin", "uninstall", p.id], dryRun: nil, cwd: nil)))
            }
        }
        return out
    }

    static func hookChecks(_ s: Snapshot) -> [Issue] {
        var out: [Issue] = []
        for h in s.hooks {
            if !h.matcherIsValid {
                out.append(Issue(severity: .problem, section: .hooks, title: "Hook matcher has the wrong format", subject: "\(h.event) · \(h.source)",
                                 detail: "A matcher must be one string (use | to combine tools), not a list. This hook may never run.", term: .hook, file: h.sourceURL))
            }
            if let script = h.scriptPath, !exists(script) {
                out.append(Issue(severity: .problem, section: .hooks, title: "Hook runs a script that does not exist", subject: "\(h.event) · \(h.source)",
                                 detail: "\(shortPath(script)) is missing, so this hook fails every time it fires.", term: .hook, file: h.sourceURL))
            }
        }
        let injecting = s.hooks.filter { ["SessionStart", "UserPromptSubmit"].contains($0.event) && !$0.async }
        if injecting.count > 3 {
            out.append(Issue(severity: .info, section: .hooks, title: "Many hooks can add text to every session", subject: "\(injecting.count) hooks",
                             detail: "SessionStart and UserPromptSubmit hooks can add up to 10,000 characters each to the context. Check what they print with /context.", term: .hook))
        }
        return out
    }

    static func permissionChecks(_ s: Snapshot) -> [Issue] {
        var out: [Issue] = []
        let broad: Set<String> = ["Bash", "Bash(*)", "Bash(:*)", "*", "Edit", "Write", "Edit(*)", "Write(*)"]
        for r in s.permissions where r.kind != "deny" && broad.contains(r.rule) {
            out.append(Issue(severity: .warning, section: .permissions, title: "Very broad permission rule", subject: "\(r.rule) · \(r.source)",
                             detail: "\(r.rule) lets Claude run that tool on anything without asking. Narrow it to specific commands or paths.", term: .permissions, file: r.sourceURL))
        }
        for src in s.settings {
            let mode = (src.root["permissions"] as? JSON)?["defaultMode"] as? String
            if mode == "bypassPermissions" {
                out.append(Issue(severity: src.scope == .project || src.scope == .local ? .info : .warning, section: .permissions,
                                 title: src.scope == .project || src.scope == .local ? "bypassPermissions in a project file is ignored" : "Permission checks are bypassed",
                                 subject: shortPath(src.url),
                                 detail: src.scope == .project || src.scope == .local ? "Claude ignores defaultMode bypassPermissions in project settings, so this line does nothing." : "defaultMode bypassPermissions skips every permission prompt.",
                                 term: .permissions, file: src.url))
            }
            if (src.scope == .project || src.scope == .local), src.root["pluginConfigs"] != nil {
                out.append(Issue(severity: .info, section: .settings, title: "pluginConfigs has no effect here", subject: shortPath(src.url),
                                 detail: "pluginConfigs is only read from user or managed settings.", term: .settings, file: src.url))
            }
        }
        let userRules = Set(s.permissions.filter { $0.kind == "allow" && $0.source.hasPrefix(Scope.user.rawValue) }.map(\.rule))
        for p in s.projects {
            let redundant = p.allowedTools.filter(userRules.contains)
            if p.allowedTools.count > 20 || !redundant.isEmpty {
                out.append(Issue(severity: .info, section: .permissions, title: "Per-project approvals have piled up", subject: (p.path as NSString).lastPathComponent,
                                 detail: "\(p.allowedTools.count) tools approved for this project\(redundant.isEmpty ? "" : ", \(redundant.count) already allowed in user settings"). Purging the project resets them; or move common ones to a user rule.",
                                 term: .allowedTools))
            }
        }
        return out
    }

    static func projectChecks(_ s: Snapshot) -> [Issue] {
        s.projects.filter { !$0.folderExists }.map { p in
            Issue(severity: .info, section: .projects, title: "Project folder no longer exists", subject: p.path,
                  detail: "Claude still keeps this entry (\(formatBytes(Int64(p.entryBytes)))) and \(p.transcriptCount) transcripts for a folder that is gone.",
                  term: .purge, fix: .cli(args: ["purge", p.path, "--yes"], dryRun: ["purge", p.path, "--dry-run"], cwd: nil),
                  bytes: Int64(p.entryBytes) + p.dataBytes)
        }
    }

    static func storageChecks(_ s: Snapshot, _ storage: [StorageArea]) -> [Issue] {
        var out: [Issue] = []
        if let scratch = storage.first(where: { $0.term == .scratch }), scratch.bytes > 1 << 30 {
            out.append(Issue(severity: .warning, section: .storage, title: "Scratch folders are large", subject: formatBytes(scratch.bytes),
                             detail: "\(scratch.itemCount) session folders in \(scratch.url.path). Claude does not clean these up. Clear finished sessions in Storage.",
                             term: .scratch, file: scratch.url, bytes: scratch.bytes))
        }
        let cutoff = Date().addingTimeInterval(-Double(s.cleanupPeriodDays + 2) * 86_400)
        let stale = s.projects.filter { ($0.lastSession ?? .distantFuture) < cutoff }
        if !stale.isEmpty {
            out.append(Issue(severity: .info, section: .storage, title: "Transcripts older than the cleanup period", subject: "\(stale.count) projects",
                             detail: "cleanupPeriodDays is \(s.cleanupPeriodDays), but \(stale.count) projects still have transcripts older than that. Cleanup runs at startup; if this persists, check the setting.",
                             term: .cleanupPeriod))
        }
        if !s.strayFiles.isEmpty {
            let bytes = s.strayFiles.reduce(0) { $0 + fileSize($1) }
            out.append(Issue(severity: .info, section: .storage, title: "Leftover backup files in ~/.claude", subject: "\(s.strayFiles.count) files",
                             detail: s.strayFiles.map(\.lastPathComponent).sorted().joined(separator: ", ") + ". Claude never reads these, and old settings copies can hold secrets.",
                             term: .strayFiles, fix: .trash(s.strayFiles), bytes: bytes))
        }
        return out
    }

    static func settingsChecks(_ s: Snapshot) -> [Issue] {
        var out: [Issue] = []
        for src in s.settings {
            let env = src.root["env"] as? [String: String] ?? [:]
            let secrets = env.filter { k, v in looksSecret(k) && !v.isEmpty && !v.hasPrefix("$") && !v.hasPrefix("/") && !v.hasPrefix("~") }
            if !secrets.isEmpty {
                out.append(Issue(severity: .problem, section: .settings, title: "Secret in settings env", subject: shortPath(src.url),
                                 detail: "\(secrets.keys.sorted().joined(separator: ", ")) are stored as plain text in this settings file.", term: .env, file: src.url))
            }
        }
        if !s.cliAvailable {
            out.append(Issue(severity: .problem, section: .settings, title: "claude command not found", subject: "CLI",
                             detail: "Fixes that use the claude CLI (purge, plugins, MCP) are unavailable.", term: .settings))
        }
        return out
    }
}

public func shortPath(_ url: URL) -> String { url.path.replacingOccurrences(of: Paths.home.path, with: "~") }

func looksSecret(_ key: String) -> Bool {
    let k = key.lowercased()
    return ["key", "token", "secret", "password", "passwd", "auth", "bearer", "credential"].contains { k.contains($0) }
}
