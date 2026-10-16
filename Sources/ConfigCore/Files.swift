import Foundation

public typealias JSON = [String: Any]

public enum Paths {
    public static let home = FileManager.default.homeDirectoryForCurrentUser
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

// MARK: - Safe writes

public enum SafeWriteError: LocalizedError, Equatable {
    case changedOnDisk
    public var errorDescription: String? {
        "The file changed on disk after it was loaded (Claude Code may have written it). Reload and redo the change."
    }
}

/// Writes `data` to `url` only if the file still has `expectedModified`; backs up first, writes atomically, keeps it owner-only.
public func safeWrite(_ data: Data, to url: URL, expectedModified: Date?, backupDir: URL = Paths.appBackups) throws -> URL? {
    let fm = FileManager.default
    if exists(url), modificationDate(url) != expectedModified { throw SafeWriteError.changedOnDisk }

    var backup: URL?
    if exists(url) {
        try fm.createDirectory(at: backupDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let target = backupDir.appending(path: "\(url.lastPathComponent).\(stamp)")
        try fm.copyItem(at: url, to: target)
        backup = target
    }

    let tmp = url.deletingLastPathComponent().appending(path: ".\(url.lastPathComponent).tmp")
    fm.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600])
    _ = try fm.replaceItemAt(url, withItemAt: tmp)
    try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    return backup
}

/// Sets one key path in a JSON settings file, keeping every other key untouched. `nil` removes the key.
public func updateSettingsKey(_ url: URL, path: [String], value: Any?, backupDir: URL = Paths.appBackups) throws -> URL? {
    let loadedAt = modificationDate(url)
    var root = readJSON(url) ?? [:]
    func set(_ dict: inout JSON, _ keys: ArraySlice<String>) {
        guard let key = keys.first else { return }
        if keys.count == 1 {
            dict[key] = value
        } else {
            var child = dict[key] as? JSON ?? [:]
            set(&child, keys.dropFirst())
            dict[key] = child
        }
    }
    set(&root, path[...])
    let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    return try safeWrite(data, to: url, expectedModified: loadedAt, backupDir: backupDir)
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
