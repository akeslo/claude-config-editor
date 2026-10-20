import Foundation

/// A backup copy Claude (or a person) left next to a config file: `settings.json.statusline-bak-20261018`, `SKILL.md.bak-20261018b`, `CLAUDE.md~`.
public struct BackupFile: Identifiable, Sendable, Hashable {
    public var id: String { url.path }
    public let url: URL
    /// The existing file it shadows; nil when no location resolves uniquely, and then Restore is disabled.
    public let original: URL?
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

    static func inBackupFolder(_ url: URL) -> Bool { url.deletingLastPathComponent().pathComponents.contains("backups") }

    static func real(_ u: URL) -> String { u.standardizedFileURL.resolvingSymlinksInPath().path }
    static func within(_ u: URL, _ root: URL) -> Bool { let r = real(root); return real(u) == r || real(u).hasPrefix(r + "/") }

    /// The existing original a backup shadows, or nil (unknown). Never a path that does not exist, so a restore cannot create a file.
    /// Only the full stem counts: a labelled leftover (`settings.json.roar.bak`, `x.json.statusline-bak-…`) is not assumed to be a copy of the live file.
    /// Next to the original: the sibling. Under `~/.claude/backups/` (resolved): known-name rules,
    /// then a unique same-name file in `index`, each target confined to ~/.claude, ~/.claude.json or a known project.
    /// Any other `backups/` folder resolves only inside its own project, never by global rules.
    public static func original(of url: URL, home: URL = Paths.home, projects: [URL] = [], index: [String: [URL]] = [:]) -> URL? {
        guard let n = stem(url.lastPathComponent) else { return nil }
        let dir = url.deletingLastPathComponent()
        guard inBackupFolder(url) else {
            let sib = dir.appending(path: n)
            // A sibling symlink pointing elsewhere is not the original.
            return exists(sib) && real(sib.deletingLastPathComponent()) == real(dir) && within(sib, dir) ? sib : nil
        }
        let claude = home.appending(path: ".claude"), claudeJSON = home.appending(path: ".claude.json")
        if within(url, claude.appending(path: "backups")) {
            let allowed = { (u: URL) in exists(u) && (within(u, claude) || real(u) == real(claudeJSON) || projects.contains { within(u, $0) }) }
            let ruled = rule(n, home: home, projects: projects)
            if let r = ruled, allowed(r) { return r }
            return unique(n, index) { allowed($0) && !within($0, claude.appending(path: "backups")) }
        }
        guard let project = projects.filter({ within(url, $0) }).max(by: { $0.path.count < $1.path.count }) else { return nil }
        return unique(n, index) { exists($0) && within($0, project) && !inBackupFolder($0) }
    }

    /// The one file named `n` passing `ok`; nil when none or several (ambiguous).
    static func unique(_ n: String, _ index: [String: [URL]], _ ok: (URL) -> Bool) -> URL? {
        let hits = (index[n] ?? []).filter(ok)
        return hits.count == 1 ? hits[0] : nil
    }

    /// Where Claude keeps a file by this name (names as backups in `~/.claude/backups/<date>/` were written).
    static func rule(_ n: String, home: URL, projects: [URL]) -> URL? {
        let claude = home.appending(path: ".claude")
        switch n {
        case "claude.json", ".claude.json": return home.appending(path: ".claude.json")
        case "history.jsonl", "settings.json", "settings.local.json", "CLAUDE.md", "keybindings.json": return claude.appending(path: n)
        case "installed_plugins.json", "known_marketplaces.json": return claude.appending(path: "plugins/\(n)")
        default: break
        }
        if n.hasSuffix(".SKILL.md") { return claude.appending(path: "skills/\(n.dropLast(9))/SKILL.md") }
        for file in ["settings.local.json", "settings.json"] where n.hasSuffix("." + file) {
            let repo = String(n.dropLast(file.count + 1))
            let hits = projects.filter { $0.lastPathComponent == repo }
            return hits.count == 1 ? hits[0].appending(path: ".claude/\(file)") : nil
        }
        return nil
    }

    /// Default roots: ~/.claude, each known project's .claude/ plus its root-level CLAUDE*.md siblings, and Claude Desktop's folder.
    public static func roots(home: URL = Paths.home, projects: [String]) -> (deep: [URL], shallow: [URL]) {
        let deep = [home.appending(path: ".claude")] + projects.map { URL(filePath: $0).appending(path: ".claude") }
        // shortcut: Desktop's folder and project roots are scanned one level deep (Desktop holds large caches); widen if backups turn up deeper.
        let shallow = [home.appending(path: "Library/Application Support/Claude")] + projects.map { URL(filePath: $0) }
        return (deep, shallow)
    }

    /// Finds backups under `deep` (recursive) and directly inside `shallow`, without following symlinks or reading binaries.
    /// `projects` (repo roots) and every non-backup file seen feed the original lookup.
    public static func scan(deep: [URL], shallow: [URL], home: URL = Paths.home, projects: [URL] = []) -> [BackupFile] {
        var seen = Set<String>(), found: [URL] = [], index: [String: [URL]] = [:]
        func consider(_ u: URL) {
            let v = try? u.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard v?.isRegularFile == true, v?.isSymbolicLink != true, !skipped.contains(where: { u.path.contains($0) }), seen.insert(u.path).inserted else { return }
            if isBackupName(u.lastPathComponent) { if isText(u) { found.append(u) } } else { index[u.lastPathComponent, default: []].append(u) }
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
        return found.map { BackupFile(url: $0, original: original(of: $0, home: home, projects: projects, index: index), size: fileSize($0), modified: modificationDate($0)) }
            .sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
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
        p.arguments = ["-u", b.original?.path ?? "/dev/null", b.url.path]
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
        guard let orig = b.original, exists(orig) else { throw Backup.BackupError.refused("original location unknown") }
        let snap = try Backup.snapshot(orig, home: home, now: now)
        try Backup.restore(Backup.Record(original: orig, copy: b.url, date: now, removed: false))
        return snap
    }
}
