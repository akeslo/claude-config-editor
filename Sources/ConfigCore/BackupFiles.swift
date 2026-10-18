import Foundation

/// A backup copy Claude (or a person) left next to a config file: `settings.json.statusline-bak-20261018`, `SKILL.md.bak-20261018b`, `CLAUDE.md~`.
public struct BackupFile: Identifiable, Sendable, Hashable {
    public var id: String { url.path }
    public let url: URL
    /// The file it shadows; may not exist any more.
    public let original: URL
    public let size: Int64
    public let modified: Date?
}

public enum BackupFiles {
    /// *.bak, *.bak-*, *.bak.*, *.backup*, *.orig, *-bak-*, *~ (leftmost marker wins).
    static let marker = try! NSRegularExpression(pattern: #"(\.bak([-.].*)?|\.backup.*|\.orig|-bak-.*|~)$"#, options: [.caseInsensitive])
    static let skipped = ["/node_modules/", "/plugins/cache/", "/.git/"]

    public static func isBackupName(_ name: String) -> Bool { stem(name) != nil }

    /// The name before the backup marker, or nil when the name has none.
    static func stem(_ name: String) -> String? {
        let ns = name as NSString
        guard let m = marker.firstMatch(in: name, range: NSRange(location: 0, length: ns.length)), m.range.location > 0 else { return nil }
        return ns.substring(to: m.range.location)
    }

    /// The original a backup shadows. A label before `-bak` (`settings.json.statusline-bak-…`) is dropped by trying
    /// shorter dot-prefixes and taking the first that exists; with none on disk, the full stem.
    public static func original(of url: URL) -> URL? {
        guard let s = stem(url.lastPathComponent) else { return nil }
        let dir = url.deletingLastPathComponent()
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        let candidates = (1...parts.count).reversed().map { parts.prefix($0).joined(separator: ".") }.filter { !$0.isEmpty }
        if let hit = candidates.first(where: { exists(dir.appending(path: $0)) }) { return dir.appending(path: hit) }
        return dir.appending(path: s)
    }

    /// Default roots: ~/.claude, each known project's .claude/ plus its root-level CLAUDE*.md siblings, and Claude Desktop's folder.
    public static func roots(home: URL = Paths.home, projects: [String]) -> (deep: [URL], shallow: [URL]) {
        let deep = [home.appending(path: ".claude")] + projects.map { URL(filePath: $0).appending(path: ".claude") }
        // shortcut: Desktop's folder and project roots are scanned one level deep (Desktop holds large caches); widen if backups turn up deeper.
        let shallow = [home.appending(path: "Library/Application Support/Claude")] + projects.map { URL(filePath: $0) }
        return (deep, shallow)
    }

    /// Finds backups under `deep` (recursive) and directly inside `shallow`, without following symlinks or reading binaries.
    public static func scan(deep: [URL], shallow: [URL]) -> [BackupFile] {
        var seen = Set<String>(), out: [BackupFile] = []
        func consider(_ u: URL) {
            let v = try? u.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard v?.isRegularFile == true, v?.isSymbolicLink != true, isBackupName(u.lastPathComponent),
                  !skipped.contains(where: { u.path.contains($0) }), isText(u), seen.insert(u.path).inserted,
                  let orig = original(of: u) else { return }
            out.append(BackupFile(url: u, original: orig, size: fileSize(u), modified: modificationDate(u)))
        }
        for root in deep {
            // The enumerator does not descend into symlinked folders, so nothing outside the root is reached.
            guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { continue }
            for case let u as URL in e {
                if ["node_modules", ".git"].contains(u.lastPathComponent) || u.path.hasSuffix("/plugins/cache") { e.skipDescendants(); continue }
                consider(u)
            }
        }
        for root in shallow { children(root).forEach(consider) }
        return out.sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
    }

    /// Config-shaped text only: no NUL in the first 8KB (rules out SQLite and other binaries).
    static func isText(_ url: URL) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? h.close() }
        return !((try? h.read(upToCount: 8192)) ?? Data()).contains(0)
    }

    /// `diff -u original backup`; "" when identical.
    public static func diff(_ b: BackupFile) -> String {
        let p = Process(), pipe = Pipe()
        p.executableURL = URL(filePath: "/usr/bin/diff")
        p.arguments = ["-u", exists(b.original) ? b.original.path : "/dev/null", b.url.path]
        p.standardOutput = pipe
        p.standardError = pipe
        guard (try? p.run()) != nil else { return "diff failed to run" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    /// Copies the backup over its original after snapshotting the current original (returned for undo). The backup is kept.
    @discardableResult
    public static func restore(_ b: BackupFile, home: URL = Paths.home, now: Date = Date()) throws -> Backup.Record? {
        let snap = exists(b.original) ? try Backup.snapshot(b.original, home: home, now: now) : nil
        try Backup.restore(Backup.Record(original: b.original, copy: b.url, date: now, removed: false))
        return snap
    }
}
