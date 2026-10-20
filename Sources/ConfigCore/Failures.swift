import Foundation

/// Things that failed to load or will fail when run: broken skills, missing plugin caches, dead hook scripts,
/// MCP servers whose command is gone, and config JSON that does not parse. All `.problem` severity, so Review files them under Broken.
public enum Failures {
    public static func detect(_ s: Snapshot, home: URL = Paths.home) -> [Issue] {
        var out: [Issue] = []
        let claudeDir = home.appending(path: ".claude")

        // Config JSON that exists but does not parse: Claude Code ignores (or refuses) the whole file.
        var jsonFiles = [home.appending(path: ".claude.json"), claudeDir.appending(path: "settings.json"),
                         claudeDir.appending(path: "settings.local.json"), claudeDir.appending(path: "plugins/installed_plugins.json")]
        for p in s.projects where p.folderExists && p.path != home.path {
            let d = URL(filePath: p.path).appending(path: ".claude")
            jsonFiles += [d.appending(path: "settings.json"), d.appending(path: "settings.local.json")]
        }
        for f in jsonFiles where exists(f) && parseError(f) != nil {
            out.append(Issue(severity: .problem, section: .settings, title: "Config file is not valid JSON", subject: shortPath(f),
                             detail: "\(parseError(f)!) Claude Code can't read this file, so none of its settings apply.", term: .settings, file: f))
        }

        // Skill folders: no SKILL.md, or a SKILL.md without frontmatter / name / description.
        // "synced" is Claude Code's cache of claude.ai skills; its skills sit one level deeper.
        var skillDirs = children(claudeDir.appending(path: "skills")).filter { $0.lastPathComponent != "synced" }
        for p in s.projects where p.folderExists && p.path != home.path {
            skillDirs += children(URL(filePath: p.path).appending(path: ".claude/skills"))
        }
        for dir in skillDirs where isDir(dir) {
            let file = dir.appending(path: "SKILL.md")
            if !exists(file) {
                out.append(broken("Skill folder has no SKILL.md", dir, "Claude Code skips this folder: a skill needs a SKILL.md inside it.", .skills, .skill, trash: dir))
                continue
            }
            let fm = Frontmatter(readText(file) ?? "")
            if fm.keys.isEmpty {
                out.append(broken("Skill has no frontmatter", file, "SKILL.md must start with a --- block holding name and description; without it Claude can't list the skill.", .skills, .skill, trash: dir))
            } else if (fm.values["description"] ?? "").isEmpty {
                out.append(broken("Skill has no description", file, "Without a description Claude never knows when to use it.", .skills, .skill, trash: dir))
            }
        }

        // Plugins whose install folder (cache) is gone.
        for p in s.plugins + s.duplicatePlugins where !exists(p.installPath) {
            out.append(Issue(severity: .problem, section: .plugins, title: "Plugin files are missing", subject: p.id,
                             detail: "\(p.id) points at \(shortPath(p.installPath)), which does not exist, so it fails to load. Reinstall or uninstall it.",
                             term: .plugin, fix: p.cli("uninstall")))
        }

        // Hook scripts that exist but can't run (missing ones are reported by Checks.hookChecks).
        for h in s.hooks {
            if let script = h.scriptPath, exists(script), !isDir(script), !FileManager.default.isExecutableFile(atPath: script.path),
               !commandRunsInterpreter(h.command) {
                out.append(Issue(severity: .problem, section: .hooks, title: "Hook script is not executable", subject: "\(h.event) · \(h.source)",
                                 detail: "\(shortPath(script)) lacks the execute bit, so the hook fails. Run chmod +x on it.", term: .hook, file: h.sourceURL))
            }
        }

        // stdio MCP servers whose program can't be found.
        for m in s.mcpServers where m.transport == "stdio" || m.transport.isEmpty {
            guard let exe = m.command.split(separator: " ").first.map(String.init), !exe.isEmpty, !exe.contains("://") else { continue }
            if resolveCommand(exe) == nil {
                out.append(Issue(severity: .problem, section: .mcp, title: "MCP server command not found", subject: "\(m.name) · \(shortPath(m.source))",
                                 detail: "\(exe) is not on disk or on PATH, so this server fails to start.", term: .mcpServer, file: m.source))
            }
        }
        return out
    }

    /// nil when the file parses as JSON; otherwise a one-line reason.
    public static func parseError(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return "Can't read the file." }
        if data.isEmpty { return "The file is empty." }
        do { _ = try JSONSerialization.jsonObject(with: data); return nil } catch {
            return ((error as NSError).userInfo[NSDebugDescriptionErrorKey] as? String) ?? error.localizedDescription
        }
    }

    /// Absolute path, ~ path, or a name looked up on PATH plus the usual install dirs.
    public static func resolveCommand(_ cmd: String, path: String = ProcessInfo.processInfo.environment["PATH"] ?? "") -> URL? {
        if cmd.contains("$") { return URL(filePath: cmd) } // shortcut: env-expanded commands can't be checked statically; assume fine.
        if cmd.hasPrefix("/") || cmd.hasPrefix("~") {
            let u = URL(filePath: NSString(string: cmd).expandingTildeInPath)
            return FileManager.default.isExecutableFile(atPath: u.path) ? u : nil
        }
        let dirs = path.split(separator: ":").map(String.init) + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin",
                    NSString(string: "~/.local/bin").expandingTildeInPath, NSString(string: "~/.bun/bin").expandingTildeInPath]
        return dirs.lazy.map { URL(filePath: $0).appending(path: cmd) }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static func commandRunsInterpreter(_ command: String) -> Bool {
        let first = command.split(separator: " ").first.map { ($0 as NSString).lastPathComponent } ?? ""
        return ["bash", "sh", "zsh", "python", "python3", "node", "bun", "ruby", "perl", "deno", "npx", "uv", "uvx"].contains(first)
    }

    static func isDir(_ u: URL) -> Bool { (try? u.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }

    static func broken(_ title: String, _ at: URL, _ detail: String, _ section: AppSection, _ term: Term, trash: URL) -> Issue {
        var i = Issue(severity: .problem, section: section, title: title, subject: shortPath(at), detail: detail, term: term, file: at)
        i.trashable = trash
        return i
    }
}
