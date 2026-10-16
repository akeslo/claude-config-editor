import Foundation

public enum Scanner {
    /// Reads every config surface. File reads are fast; the two CLI calls run in parallel.
    public static func load() async -> Snapshot {
        async let pluginJSON = ClaudeCLI.json(["plugin", "list", "--json"])
        async let version = ClaudeCLI.run(["--version"])

        var snap = Snapshot()
        let claudeJSON = readJSON(Paths.claudeJSON) ?? [:]
        snap.claudeJSONModified = modificationDate(Paths.claudeJSON)
        snap.claudeJSONBytes = fileSize(Paths.claudeJSON)
        snap.projects = projects(from: claudeJSON)
        let projectPaths = snap.projects.filter(\.folderExists).map(\.path)
        // In the home folder, <project>/.claude is ~/.claude itself; don't count user files twice.
        let repoPaths = projectPaths.filter { $0 != Paths.home.path }

        snap.settings = settingsSources(projectPaths: repoPaths)
        // The same plugin can be installed in several scopes; keep one row per id (enabled first).
        var seen = Set<String>()
        for p in plugins(from: await pluginJSON, usage: claudeJSON["pluginUsage"] as? JSON ?? [:]).sorted(by: { $0.enabled && !$1.enabled }) {
            if seen.insert(p.id).inserted { snap.plugins.append(p) } else { snap.duplicatePlugins.append(p) }
        }
        snap.plugins.sort { $0.id < $1.id }
        let enabledPlugins = snap.plugins.filter(\.enabled)

        snap.mcpServers = mcpServers(claudeJSON: claudeJSON, projectPaths: projectPaths, plugins: enabledPlugins)
        snap.components = components(projectPaths: repoPaths, plugins: enabledPlugins, usage: claudeJSON["skillUsage"] as? JSON ?? [:])
        let overrides = snap.setting("skillOverrides")?.value as? [String: String] ?? [:]
        for i in snap.components.indices { snap.components[i].override = overrides[snap.components[i].name] }
        snap.hooks = hooks(settings: snap.settings, plugins: enabledPlugins)
        snap.permissions = permissions(settings: snap.settings, projects: snap.projects)
        snap.instructions = instructions(projects: snap.projects)
        snap.strayFiles = children(Paths.claudeDir).filter { isStray($0.lastPathComponent) }
        let v = await version
        snap.claudeVersion = v.ok ? v.output.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        return snap
    }

    // MARK: Projects

    static func projects(from claudeJSON: JSON) -> [Project] {
        let entries = claudeJSON["projects"] as? JSON ?? [:]
        return entries.map { path, value in
            let e = value as? JSON ?? [:]
            let bytes = (try? JSONSerialization.data(withJSONObject: e))?.count ?? 0
            let dataDir = Paths.projectDataDir(for: path)
            let sessions = children(dataDir).filter { $0.pathExtension == "jsonl" }
            var p = Project(
                path: path, entryBytes: bytes,
                allowedTools: e["allowedTools"] as? [String] ?? [],
                mcpServerNames: (e["mcpServers"] as? JSON)?.keys.sorted() ?? [],
                trusted: e["hasTrustDialogAccepted"] as? Bool ?? false,
                dataDir: dataDir)
            p.transcriptCount = sessions.count
            p.lastSession = sessions.compactMap(modificationDate).max()
            return p
        }.sorted { $0.entryBytes > $1.entryBytes }
    }

    // MARK: Settings

    static func settingsSources(projectPaths: [String]) -> [SettingsSource] {
        var files: [(Scope, URL, String?)] = [
            (.managed, Paths.managedSettings, nil),
            (.user, Paths.userSettings, nil),
            (.userLocal, Paths.userLocalSettings, nil),
        ]
        for p in projectPaths {
            let dir = URL(filePath: p).appending(path: ".claude")
            files.append((.project, dir.appending(path: "settings.json"), p))
            files.append((.local, dir.appending(path: "settings.local.json"), p))
        }
        return files.compactMap { scope, url, project in
            guard let json = readJSON(url) else { return nil }
            return SettingsSource(scope: scope, url: url, project: project, root: json, modified: modificationDate(url))
        }
    }

    // MARK: Plugins

    static func plugins(from json: Any?, usage: JSON) -> [Plugin] {
        let installed = (json as? JSON)?["installed"] as? [JSON] ?? json as? [JSON] ?? []
        return installed.compactMap { p in
            guard let id = p["id"] as? String else { return nil }
            let u = usage[id] as? JSON
            var plugin = Plugin(
                id: id, version: p["version"] as? String ?? "?", scope: p["scope"] as? String ?? "user",
                enabled: p["enabled"] as? Bool ?? false,
                installPath: URL(filePath: p["installPath"] as? String ?? ""),
                notes: p["notes"] as? [String] ?? [])
            plugin.usageCount = u?["usageCount"] as? Int ?? 0
            plugin.lastUsed = (u?["lastUsedAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
            return plugin
        }.sorted { $0.id < $1.id }
    }

    public static func available() async -> [AvailablePlugin] {
        let json = await ClaudeCLI.json(["plugin", "list", "--json", "--available"]) as? JSON ?? [:]
        let installedIDs = Set((json["installed"] as? [JSON] ?? []).compactMap { $0["id"] as? String })
        return (json["available"] as? [JSON] ?? []).compactMap { p in
            guard let id = p["pluginId"] as? String else { return nil }
            return AvailablePlugin(
                id: id, name: p["name"] as? String ?? id, description: p["description"] as? String ?? "",
                marketplace: p["marketplaceName"] as? String ?? "", installCount: p["installCount"] as? Int ?? 0,
                installed: installedIDs.contains(id))
        }.sorted { $0.installCount > $1.installCount }
    }

    public static func alwaysOnTokens(plugin id: String) async -> Int? {
        parseAlwaysOn(await ClaudeCLI.run(["plugin", "details", id]).output)
    }

    /// Parses the "Always-on:   ~641 tok" (or "~1.2k tok") line of `claude plugin details`.
    static func parseAlwaysOn(_ output: String) -> Int? {
        guard let line = output.split(separator: "\n").first(where: { $0.contains("Always-on:") }),
              let m = line.firstMatch(of: /~?([0-9.,]+)(k?)\s*tok/),
              let value = Double(m.1.replacingOccurrences(of: ",", with: "")) else { return nil }
        return Int(m.2 == "k" ? value * 1000 : value)
    }

    // MARK: MCP

    static func mcpServers(claudeJSON: JSON, projectPaths: [String], plugins: [Plugin]) -> [MCPServer] {
        var out: [MCPServer] = []
        func add(_ dict: Any?, _ scope: Scope, _ project: String?, _ source: URL) {
            for (name, v) in dict as? JSON ?? [:] {
                let s = v as? JSON ?? [:]
                let command = ([s["command"] as? String ?? s["url"] as? String ?? ""] + (s["args"] as? [String] ?? [])).joined(separator: " ")
                let raw = (try? JSONSerialization.data(withJSONObject: s, options: [.prettyPrinted, .sortedKeys])).map { String(decoding: $0, as: UTF8.self) } ?? ""
                out.append(MCPServer(
                    name: name, scope: scope, project: project, source: source, command: command,
                    transport: s["type"] as? String ?? (s["url"] != nil ? "http" : "stdio"),
                    env: s["env"] as? [String: String] ?? [:], headers: s["headers"] as? [String: String] ?? [:], raw: raw))
            }
        }
        add(claudeJSON["mcpServers"], .user, nil, Paths.claudeJSON)
        for (path, v) in claudeJSON["projects"] as? JSON ?? [:] {
            add((v as? JSON)?["mcpServers"], .local, path, Paths.claudeJSON)
        }
        for p in projectPaths {
            let url = URL(filePath: p).appending(path: ".mcp.json")
            add(readJSON(url)?["mcpServers"], .project, p, url)
        }
        for p in plugins {
            let url = p.installPath.appending(path: ".mcp.json")
            let json = readJSON(url)
            add(json?["mcpServers"] ?? json, .plugin, p.id, url)
        }
        add(readJSON(Paths.desktopConfig)?["mcpServers"], .desktop, nil, Paths.desktopConfig)
        return out.sorted { ($0.name, $0.scope.rawValue) < ($1.name, $1.scope.rawValue) }
    }

    // MARK: Skills, agents, commands, output styles

    static func components(projectPaths: [String], plugins: [Plugin], usage: JSON) -> [Component] {
        var out: [Component] = []
        func scan(_ base: URL, scope: Scope, owner: String?, prefix: String) {
            for dir in children(base.appending(path: "skills")) {
                let file = dir.appending(path: "SKILL.md")
                if exists(file) { out.append(component(.skill, file, dir.lastPathComponent, scope, owner, prefix)) }
            }
            let flat: [(String, ComponentKind)] = [("agents", .subagent), ("commands", .command), ("output-styles", .outputStyle)]
            for (folder, kind) in flat {
                for file in children(base.appending(path: folder)) where file.pathExtension == "md" {
                    out.append(component(kind, file, file.deletingPathExtension().lastPathComponent, scope, owner, prefix))
                }
            }
        }
        scan(Paths.claudeDir, scope: .user, owner: nil, prefix: "")
        for p in projectPaths { scan(URL(filePath: p).appending(path: ".claude"), scope: .project, owner: p, prefix: "") }
        for p in plugins {
            let name = p.id.split(separator: "@").first.map(String.init) ?? p.id
            scan(p.installPath, scope: .plugin, owner: p.id, prefix: "\(name):")
        }
        return out.map { c in
            var c = c
            let u = usage[c.name] as? JSON
            c.usageCount = u?["usageCount"] as? Int ?? 0
            c.lastUsed = (u?["lastUsedAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
            return c
        }
    }

    static func component(_ kind: ComponentKind, _ file: URL, _ baseName: String, _ scope: Scope, _ owner: String?, _ prefix: String) -> Component {
        let text = readText(file) ?? ""
        let fm = Frontmatter(text)
        let name = prefix + (fm.values["name"] ?? baseName)
        let description = [fm.values["description"], fm.values["when_to_use"]].compactMap { $0 }.joined(separator: " ")
        return Component(
            kind: kind, name: name, scope: scope, owner: owner, file: file, description: description,
            lineCount: text.split(separator: "\n", omittingEmptySubsequences: false).count,
            alwaysLoaded: fm.values["disable-model-invocation"] != "true" && kind != .outputStyle,
            frontmatterKeys: fm.keys)
    }

    // MARK: Hooks

    static func hooks(settings: [SettingsSource], plugins: [Plugin]) -> [Hook] {
        var out: [Hook] = []
        func add(_ tree: Any?, source: String, url: URL, pluginRoot: URL?) {
            for (event, groups) in tree as? JSON ?? [:] {
                for group in groups as? [JSON] ?? [] {
                    let rawMatcher = group["matcher"]
                    for h in group["hooks"] as? [JSON] ?? [] {
                        let command = h["command"] as? String ?? h["url"] as? String ?? h["prompt"] as? String ?? "(\(h["type"] as? String ?? "?"))"
                        out.append(Hook(
                            event: event, matcher: rawMatcher as? String, matcherIsValid: rawMatcher == nil || rawMatcher is String,
                            command: command, timeout: h["timeout"] as? Int, async: h["async"] as? Bool ?? false,
                            source: source, sourceURL: url, scriptPath: scriptPath(in: command, pluginRoot: pluginRoot)))
                    }
                }
            }
        }
        for s in settings {
            add(s.root["hooks"], source: s.project.map { "\(s.scope.rawValue) · \(($0 as NSString).lastPathComponent)" } ?? s.scope.rawValue, url: s.url, pluginRoot: nil)
        }
        for p in plugins {
            let url = p.installPath.appending(path: "hooks/hooks.json")
            add(readJSON(url)?["hooks"], source: "Plugin · \(p.id)", url: url, pluginRoot: p.installPath)
        }
        return out.sorted { ($0.event, $0.source) < ($1.event, $1.source) }
    }

    /// Finds a script file a hook command runs, so we can check it still exists.
    static func scriptPath(in command: String, pluginRoot: URL?) -> URL? {
        let expanded = command
            .replacingOccurrences(of: "${CLAUDE_PLUGIN_ROOT}", with: pluginRoot?.path ?? "${CLAUDE_PLUGIN_ROOT}")
            .replacingOccurrences(of: "$CLAUDE_PLUGIN_ROOT", with: pluginRoot?.path ?? "$CLAUDE_PLUGIN_ROOT")
        for token in expanded.split(separator: " ") {
            let t = token.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            guard t.hasPrefix("/") || t.hasPrefix("~/"), !t.contains("$") else { continue }
            return URL(filePath: NSString(string: t).expandingTildeInPath)
        }
        return nil
    }

    // MARK: Permissions

    static func permissions(settings: [SettingsSource], projects: [Project]) -> [PermissionRule] {
        var out: [PermissionRule] = []
        for s in settings {
            let perms = s.root["permissions"] as? JSON ?? [:]
            let source = s.project.map { "\(s.scope.rawValue) · \(($0 as NSString).lastPathComponent)" } ?? s.scope.rawValue
            for kind in ["allow", "ask", "deny"] {
                for rule in perms[kind] as? [String] ?? [] {
                    out.append(PermissionRule(kind: kind, rule: rule, source: source, sourceURL: s.url))
                }
            }
        }
        for p in projects {
            for rule in p.allowedTools {
                out.append(PermissionRule(kind: "allowedTools", rule: rule, source: "Project · \((p.path as NSString).lastPathComponent)", sourceURL: Paths.claudeJSON))
            }
        }
        return out
    }

    // MARK: Instructions and memory

    static func instructions(projects: [Project]) -> [InstructionFile] {
        var out: [InstructionFile] = []
        func add(_ kind: InstructionFile.Kind, _ url: URL, _ project: String?, maxLines: Int? = nil) {
            guard let text = readText(url) else { return }
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            let loaded = maxLines.map { lines.prefix($0).joined(separator: "\n") } ?? text
            let fm = Frontmatter(text)
            var f = InstructionFile(kind: kind, url: url, project: project, lines: lines.count, tokens: estimateTokens(loaded), pathScoped: fm.keys.contains("paths"))
            switch kind {
            case .claudeMD where lines.count > 200, .localMD where lines.count > 200:
                f.problems.append("\(lines.count) lines; the docs recommend under 200.")
            case .memoryIndex:
                f.problems += memoryProblems(index: url, text: text, lineCount: lines.count)
            case .localMD:
                if let project, !isGitIgnored(url, repo: URL(filePath: project)) { f.problems.append("Not in .gitignore, so it may get committed.") }
            default: break
            }
            out.append(f)
        }
        func rules(_ dir: URL, _ project: String?) {
            guard let en = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else { return }
            for case let f as URL in en where f.pathExtension == "md" { add(.rule, f, project) }
        }
        add(.claudeMD, Paths.userClaudeMD, nil)
        rules(Paths.claudeDir.appending(path: "rules"), nil)
        for p in projects where p.folderExists {
            let root = URL(filePath: p.path)
            add(.claudeMD, root.appending(path: "CLAUDE.md"), p.path)
            add(.localMD, root.appending(path: "CLAUDE.local.md"), p.path)
            guard p.path != Paths.home.path else { continue }
            add(.claudeMD, root.appending(path: ".claude/CLAUDE.md"), p.path)
            rules(root.appending(path: ".claude/rules"), p.path)
        }
        let byDataDir = Dictionary(projects.map { ($0.dataDir.lastPathComponent, $0.path) }, uniquingKeysWith: { a, _ in a })
        for dir in children(Paths.claudeDir.appending(path: "projects")) {
            add(.memoryIndex, dir.appending(path: "memory/MEMORY.md"), byDataDir[dir.lastPathComponent] ?? dir.lastPathComponent, maxLines: 200)
        }
        return out
    }

    static func memoryProblems(index: URL, text: String, lineCount: Int) -> [String] {
        var problems: [String] = []
        if lineCount > 200 { problems.append("\(lineCount) lines; only the first 200 load at session start.") }
        let dir = index.deletingLastPathComponent()
        let linked = Set(text.matches(of: /\]\(([^)\s]+\.md)\)/).map { String($0.1) })
        let missing = linked.filter { !exists(dir.appending(path: $0)) }
        if !missing.isEmpty { problems.append("Links to missing files: \(missing.sorted().joined(separator: ", "))") }
        let orphans = children(dir).map(\.lastPathComponent).filter { $0.hasSuffix(".md") && $0 != "MEMORY.md" && !linked.contains($0) }
        if !orphans.isEmpty { problems.append("Files not linked from MEMORY.md: \(orphans.sorted().joined(separator: ", "))") }
        return problems
    }

    static func isGitIgnored(_ file: URL, repo: URL) -> Bool {
        guard exists(repo.appending(path: ".git")) else { return true }  // not a repo: nothing to commit it to
        let p = Process()
        p.executableURL = URL(filePath: "/usr/bin/git")
        // Project repos are untrusted: disable config that can run commands.
        p.arguments = ["-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null", "-C", repo.path, "check-ignore", "-q", file.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return true }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    static func isStray(_ name: String) -> Bool {
        name.contains(".bak") || name.contains(".pre-") || name.hasSuffix(".old") || name.hasSuffix(".orig") || name.hasSuffix("~")
    }

    // MARK: Storage

    public static func storageAreas() -> [StorageArea] {
        let c = Paths.claudeDir
        let known: [(String, URL, StorageArea.Safety, Term, Bool)] = [
            ("Scratch & task output", Paths.scratchRoot, .safe, .scratch, false),
            ("Transcripts & project data", c.appending(path: "projects"), .care, .transcripts, true),
            ("Plugins", c.appending(path: "plugins"), .keep, .pluginData, false),
            ("Background jobs", c.appending(path: "jobs"), .care, .jobs, false),
            ("File history", c.appending(path: "file-history"), .safe, .fileHistory, true),
            ("Claude's backups", c.appending(path: "backups"), .keep, .claudeBackups, false),
            ("This app's backups", Paths.appBackups, .care, .appBackups, false),
            ("Paste cache", c.appending(path: "paste-cache"), .safe, .caches, false),
            ("Image cache", c.appending(path: "image-cache"), .safe, .caches, true),
            ("Cache", c.appending(path: "cache"), .safe, .caches, false),
            ("Shell snapshots", c.appending(path: "shell-snapshots"), .safe, .caches, false),
            ("Debug logs", c.appending(path: "debug"), .safe, .caches, false),
            ("Session env", c.appending(path: "session-env"), .safe, .caches, false),
            ("Todos (legacy)", c.appending(path: "todos"), .safe, .caches, true),
            ("Statsig (legacy)", c.appending(path: "statsig"), .safe, .caches, true),
            ("Logs (legacy)", c.appending(path: "logs"), .safe, .caches, true),
        ]
        let knownPaths = Set(known.map(\.1.path))
        // Folders Claude Code documents as its own but that hold config, not bulk data.
        let configDirs: Set<String> = ["skills", "agents", "commands", "output-styles", "rules", "hooks", "themes", "plans", "sessions", "state"]
        var areas = known.filter { exists($0.1) }.map { StorageArea(name: $0.0, url: $0.1, safety: $0.2, term: $0.3, autoCleaned: $0.4) }
        for dir in children(c) where (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            guard !knownPaths.contains(dir.path), !configDirs.contains(dir.lastPathComponent) else { continue }
            areas.append(StorageArea(name: dir.lastPathComponent, url: dir, safety: .unknown, term: .unknownFolder, autoCleaned: false))
        }
        return areas
    }

    public static func measure(_ area: StorageArea) -> StorageArea {
        var a = area
        let items = children(area.url)
        a.itemCount = items.count
        a.oldest = items.compactMap(modificationDate).min()
        a.bytes = directorySize(area.url)
        return a
    }
}

/// Minimal YAML frontmatter reader: top-level `key: value`, folded `>`/`|` blocks, and quoted strings.
struct Frontmatter {
    var keys: [String] = []
    var values: [String: String] = [:]

    init(_ text: String) {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else { return }
        var current: String?
        var block: [String] = []
        func flush() {
            if let k = current, !block.isEmpty { values[k] = block.joined(separator: " ").trimmingCharacters(in: .whitespaces) }
            block = []
        }
        for line in lines[1..<end] {
            if let first = line.first, first != " ", first != "\t", first != "-", let colon = line.firstIndex(of: ":") {
                flush()
                let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
                var value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                keys.append(key)
                current = key
                if ["|", ">", "|-", ">-", ""].contains(value) { continue }
                if value.count >= 2, let q = value.first, q == "\"" || q == "'", value.last == q { value = String(value.dropFirst().dropLast()) }
                values[key] = value
                current = nil
            } else if current != nil {
                block.append(line.trimmingCharacters(in: .whitespaces))
            }
        }
        flush()
    }
}
