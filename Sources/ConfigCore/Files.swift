import Foundation

public typealias JSON = [String: Any]

public enum Paths {
    /// `CLAUDE_CONFIG_EDITOR_HOME` points the whole app at a fixture copy (testing); else the real home.
    public static let home = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_EDITOR_HOME"]
        .flatMap { $0.isEmpty ? nil : URL(filePath: $0, directoryHint: .isDirectory) } ?? FileManager.default.homeDirectoryForCurrentUser
    public static let claudeDir = home.appending(path: ".claude")
    public static let claudeJSON = home.appending(path: ".claude.json")
    public static let userSettings = claudeDir.appending(path: "settings.json")
    public static let userLocalSettings = claudeDir.appending(path: "settings.local.json")
    public static let managedSettings = URL(filePath: "/Library/Application Support/ClaudeCode/managed-settings.json")
    public static let keybindings = claudeDir.appending(path: "keybindings.json")
    public static let userClaudeMD = claudeDir.appending(path: "CLAUDE.md")
    public static let desktopConfig = home.appending(path: "Library/Application Support/Claude/claude_desktop_config.json")
    public static let scratchRoot = URL(filePath: "/private/tmp/claude-\(getuid())")
    /// This app's own backups, kept apart from Claude's `~/.claude/backups/` rotation of 5.
    public static let appBackups = claudeDir.appending(path: "config-editor-backups")

    /// Claude stores per-project data under `~/.claude/projects/<path with every non-alphanumeric char as ->`.
    public static func projectDataDir(for projectPath: String) -> URL {
        let encoded = String(projectPath.map { $0.isLetter || $0.isNumber ? $0 : "-" })
        return claudeDir.appending(path: "projects/\(encoded)")
    }
}

public func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

public func readJSON(_ url: URL) -> JSON? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? JSON
}

public func readText(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }

public func modificationDate(_ url: URL) -> Date? {
    (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
}

public func fileSize(_ url: URL) -> Int64 {
    ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
}

/// Rough token estimate (about 4 characters per token). Shown with "≈" in the UI.
public func estimateTokens(_ text: String) -> Int { (text.count + 3) / 4 }

public func formatBytes(_ n: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
}

public func formatTokens(_ n: Int) -> String {
    n >= 1000 ? String(format: "≈%.1fk tok", Double(n) / 1000) : "≈\(n) tok"
}

// MARK: - Safe writes (all through `ConfigWriter`)

/// Sets one key path in a JSON settings file, keeping every other key untouched. `nil` removes the key. Returns the backup.
@discardableResult
public func updateSettingsKey(_ url: URL, path: [String], value: Any?, home: URL = Paths.home) throws -> URL? {
    try ConfigWriter.mutateJSON(url, home: home, expectedModified: modificationDate(url)) { ScopeMove.set(&$0, path[...], value) }
}

/// One hook entry in a settings file: its event, matcher group and command.
public struct HookRef: Sendable, Hashable {
    public let file: URL, event: String, matcher: String?, command: String
    public init(file: URL, event: String, matcher: String?, command: String) { self.file = file; self.event = event; self.matcher = matcher; self.command = command }
}

/// Removes the given hooks from one settings file (matched by event, matcher and command), dropping groups and events left empty. Returns the backup.
@discardableResult
public func removeHooks(_ url: URL, _ refs: [HookRef], home: URL = Paths.home) throws -> URL? {
    try ConfigWriter.mutateJSON(url, home: home, expectedModified: modificationDate(url)) { root in
        var hooks = root["hooks"] as? JSON ?? [:]
        for (event, groups) in hooks {
            let mine = refs.filter { $0.event == event }
            guard !mine.isEmpty else { continue }
            let kept: [JSON] = (groups as? [JSON] ?? []).compactMap { g in
                var g = g
                let gone = Set(mine.filter { $0.matcher == g["matcher"] as? String }.map(\.command))
                let hs = (g["hooks"] as? [JSON] ?? []).filter { !gone.contains($0["command"] as? String ?? $0["url"] as? String ?? $0["prompt"] as? String ?? "") }
                if hs.isEmpty { return nil }
                g["hooks"] = hs
                return g
            }
            hooks[event] = kept.isEmpty ? nil : kept
        }
        root["hooks"] = hooks.isEmpty ? nil : hooks
    }
}

// MARK: - Folder sizes

public func directorySize(_ url: URL) -> Int64 {
    guard let en = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey], options: []) else {
        return fileSize(url)
    }
    var total: Int64 = 0
    for case let f as URL in en {
        let v = try? f.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
        if v?.isRegularFile == true { total += Int64(v?.totalFileAllocatedSize ?? 0) }
    }
    return total
}

public func children(_ url: URL) -> [URL] {
    (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
}

/// Why `url` must not go to the Trash, or nil when it may. Live config and whole working folders are never trashed.
public func trashRefusal(_ url: URL) -> String? {
    let path = url.standardizedFileURL.path
    // plugins/ and backups/ match the Storage areas marked "keep".
    let core = ["/", Paths.home.path, Paths.claudeDir.path, Paths.claudeJSON.path,
                Paths.claudeDir.appending(path: "plugins").path, Paths.claudeDir.appending(path: "backups").path]
    if core.contains(path) { return "core Claude location" }
    if ["settings.json", "settings.local.json", "managed-settings.json"].contains(url.lastPathComponent) { return "live settings file" }
    let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? url.hasDirectoryPath
    // A folder must be Claude data (inside some .claude dir, or scratch); anything else could be a project's working folder.
    if isDir, !url.standardizedFileURL.pathComponents.dropLast().contains(".claude"), !path.hasPrefix(Paths.scratchRoot.path) {
        return "not a Claude data folder"
    }
    return nil
}

/// "owner/repo" for a GitHub URL, else nil.
public func githubSlug(_ url: URL?) -> String? {
    guard let u = url, u.host == "github.com" else { return nil }
    let parts = u.pathComponents.filter { $0 != "/" }
    guard parts.count >= 2 else { return nil }
    return parts[0] + "/" + (parts[1].hasSuffix(".git") ? String(parts[1].dropLast(4)) : parts[1])
}
