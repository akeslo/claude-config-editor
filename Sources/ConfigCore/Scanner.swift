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
        let known = readJSON(Paths.claudeDir.appending(path: "plugins/known_marketplaces.json"))
        for i in snap.plugins.indices {
            snap.plugins[i].repoURL = repoURL(pluginRoot: snap.plugins[i].installPath, marketplace: snap.plugins[i].marketplace, known: known)
            let root = snap.plugins[i].installPath
            snap.plugins[i].description = readJSON(root.appending(path: ".claude-plugin/plugin.json"))?["description"] as? String
                ?? readmeSummary(root.appending(path: "README.md")) ?? ""
        }
        let shas = (readJSON(Paths.claudeDir.appending(path: "plugins/installed_plugins.json"))?["plugins"] as? JSON ?? [:])
            .compactMapValues { (($0 as? [JSON])?.first?["gitCommitSha"]) as? String }
        for i in snap.plugins.indices {
            let p = snap.plugins[i]
            snap.plugins[i].latestVersion = newerVersion(plugin: p.id, version: p.version, sha: shas[p.id],
                                                         marketplaceDir: Paths.claudeDir.appending(path: "plugins/marketplaces/\(p.marketplace)"))
        }
        let enabledPlugins = snap.plugins.filter(\.enabled)

        snap.mcpServers = mcpServers(claudeJSON: claudeJSON, projectPaths: projectPaths, plugins: enabledPlugins)
        for i in snap.mcpServers.indices {
            let m = snap.mcpServers[i]
            snap.mcpServers[i].description = (m.scope == .plugin ? snap.plugins.first { $0.id == m.project }?.description : nil) ?? npmDescription(m.command) ?? ""
        }
        snap.components = components(projectPaths: repoPaths, plugins: enabledPlugins, usage: claudeJSON["skillUsage"] as? JSON ?? [:])
        let overrides = snap.setting("skillOverrides")?.value as? [String: String] ?? [:]
        for i in snap.components.indices {
            snap.components[i].override = overrides[snap.components[i].name]
            if let plugin = snap.plugins.first(where: { $0.id == snap.components[i].owner }) { snap.components[i].repoURL = plugin.repoURL; snap.components[i].pluginScope = plugin.scope }
        }
        snap.hooks = hooks(settings: snap.settings, plugins: enabledPlugins)
        snap.permissions = permissions(settings: snap.settings, projects: snap.projects)
        snap.instructions = instructions(projects: snap.projects)
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
        return installed.compactMap { p -> Plugin? in
            guard let id = p["id"] as? String else { return nil }
            let u = usage[id] as? JSON
            var plugin = Plugin(
                id: id, version: p["version"] as? String ?? "?", scope: p["scope"] as? String ?? "user",
                enabled: p["enabled"] as? Bool ?? false,
                installPath: URL(filePath: p["installPath"] as? String ?? ""),
                notes: p["notes"] as? [String] ?? [])
            plugin.projectPath = p["projectPath"] as? String
            plugin.enabled = enabledWhereInstalled(plugin)
            plugin.usageCount = u?["usageCount"] as? Int ?? 0
            plugin.lastUsed = (u?["lastUsedAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
            return plugin
        }.sorted { $0.id < $1.id }
    }

    /// The CLI reports enabled state for the folder it runs in (home); a project/local install is on or off in its own folder's settings.
    public static func enabledWhereInstalled(_ p: Plugin) -> Bool {
        guard p.scope != "user", let dir = p.projectPath else { return p.enabled }
        let files = p.scope == "local" ? ["settings.local.json", "settings.json"] : ["settings.json", "settings.local.json"]
        for f in files {
            if let on = (readJSON(URL(filePath: dir).appending(path: ".claude/" + f))?["enabledPlugins"] as? [String: Bool])?[p.id] { return on }
        }
        return p.enabled
    }

    /// The `origin` URL from the nearest enclosing git checkout's config, read without running git.
    static func gitRemote(_ start: URL) -> URL? {
        var dir = start
        for _ in 0..<5 {
            if let config = readText(dir.appending(path: ".git/config")) {
                var inOrigin = false
                for line in config.split(separator: "\n").map({ $0.trimmingCharacters(in: .whitespaces) }) {
                    if line.hasPrefix("[") { inOrigin = line == #"[remote "origin"]"# }
                    else if inOrigin, line.hasPrefix("url"), let eq = line.firstIndex(of: "=") {
                        return URL(string: line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                        .replacingOccurrences(of: "git@github.com:", with: "https://github.com/"))
                    }
                }
                return nil
            }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }

    /// Where a plugin's source lives: its plugin.json repository/homepage, else the marketplace it came from.
    public static func repoURL(pluginRoot: URL, marketplace: String, known: JSON?) -> URL? {
        let manifest = readJSON(pluginRoot.appending(path: ".claude-plugin/plugin.json"))
        let repo = manifest?["repository"]
        for s in [repo as? String, (repo as? JSON)?["url"] as? String, manifest?["homepage"] as? String].compactMap({ $0 }) {
            if let u = URL(string: s.replacingOccurrences(of: "git+", with: "")), ["http", "https"].contains(u.scheme) { return u }
        }
        return marketplaceRepo(marketplace, known: known)
    }

    public static func marketplaceRepo(_ name: String, known: JSON?) -> URL? {
        let source = (known?[name] as? JSON)?["source"] as? JSON
        if let repo = source?["repo"] as? String { return URL(string: "https://github.com/\(repo)") }
        if let url = source?["url"] as? String, let u = URL(string: url), ["http", "https"].contains(u.scheme) { return u }
        return nil
    }

    public static func available() async -> [AvailablePlugin] {
        let json = await ClaudeCLI.json(["plugin", "list", "--json", "--available"]) as? JSON ?? [:]
        let known = readJSON(Paths.claudeDir.appending(path: "plugins/known_marketplaces.json"))
        let installedIDs = Set((json["installed"] as? [JSON] ?? []).compactMap { $0["id"] as? String })
        return (json["available"] as? [JSON] ?? []).compactMap { p in
            guard let id = p["pluginId"] as? String else { return nil }
            return AvailablePlugin(
                id: id, name: p["name"] as? String ?? id, description: p["description"] as? String ?? "",
                marketplace: p["marketplaceName"] as? String ?? "", installCount: p["installCount"] as? Int ?? 0,
                installed: installedIDs.contains(id),
                repoURL: marketplaceRepo(p["marketplaceName"] as? String ?? "", known: known))
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

    /// The marketplace's version of a plugin when it differs from the installed one. Offline: Claude Code refreshes
    /// marketplaces itself at startup. Plugins pinned by neither a version nor a commit give nil (unknown).
    static func newerVersion(plugin id: String, version: String, sha: String?, marketplaceDir: URL) -> String? {
        let name = String(id.split(separator: "@").first ?? "")
        guard let entry = (readJSON(marketplaceDir.appending(path: ".claude-plugin/marketplace.json"))?["plugins"] as? [JSON])?
            .first(where: { $0["name"] as? String == name }) else { return nil }
        if let v = entry["version"] as? String ?? (entry["source"] as? String).flatMap({
            readJSON(marketplaceDir.appending(path: $0).appending(path: ".claude-plugin/plugin.json"))?["version"] as? String
        }) {
            return v == version ? nil : v
        }
        if let latest = (entry["source"] as? JSON)?["sha"] as? String, let sha {
            return latest == sha ? nil : String(latest.prefix(12))
        }
        return nil
    }

    /// First prose line of a README, skipping headings, badges and blank lines.
    static func readmeSummary(_ url: URL) -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !"#![<`|-".contains($0.first!) }
    }

    /// Offline lookup: the package's package.json in ~/.npm/_npx, if npx has fetched it before.
    static func npmDescription(_ command: String) -> String? {
        let words = command.split(separator: " ").map(String.init)
        guard words.first.map({ ["npx", "bunx", "pnpx"].contains(($0 as NSString).lastPathComponent) }) == true,
              let spec = words.dropFirst().first(where: { !$0.hasPrefix("-") }) else { return nil }
        // Strip a version: "pkg@1.2", "@scope/pkg@latest".
        let name = spec.hasPrefix("@") ? spec.split(separator: "@").first.map { "@" + $0 } ?? spec : String(spec.split(separator: "@").first ?? "")
        let cache = Paths.home.appending(path: ".npm/_npx")
        for dir in children(cache) {
            if let d = readJSON(dir.appending(path: "node_modules/\(name)/package.json"))?["description"] as? String { return d }
        }
        return nil
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
        out = mergeAgentSkills(out, dirs: SkillAgent.otherSkillDirs())
        let lock = readJSON(Paths.home.appending(path: ".agents/.skill-lock.json"))?["skills"] as? JSON ?? [:]
        return out.map { c in
            var c = c
            let folder = c.kind == .skill ? c.file.deletingLastPathComponent() : c.file
            let entry = lock[folder.lastPathComponent] as? JSON
            c.repoURL = (entry?["sourceUrl"] as? String).flatMap(URL.init(string:)) ?? gitRemote(folder.resolvingSymlinksInPath())
            c.installedAt = (entry?["installedAt"] as? String).flatMap { try? Date($0, strategy: .iso8601) }
                ?? (try? folder.resourceValues(forKeys: [.creationDateKey]))?.creationDate
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
