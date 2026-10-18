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

    /// `a.b.c` → [`a.b.c`, `a.b`, `a`]: a label before the marker (`settings.json.statusline-bak-…`) is dropped by trying shorter names.
    static func candidates(_ s: String) -> [String] {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        return (1...parts.count).reversed().map { parts.prefix($0).joined(separator: ".") }.filter { !$0.isEmpty }
    }

    static func inBackupFolder(_ url: URL) -> Bool { url.deletingLastPathComponent().pathComponents.contains("backups") }

    /// The existing original a backup shadows, or nil (unknown). Never a path that does not exist, so a restore cannot create a file.
    /// Next to the original: the sibling. Inside a `backups/` folder: a manifest/README line naming it, then known-name rules, then a unique same-name file in `index`.
    public static func original(of url: URL, home: URL = Paths.home, projects: [URL] = [], index: [String: [URL]] = [:]) -> URL? {
        guard let s = stem(url.lastPathComponent) else { return nil }
        let names = candidates(s)
        guard inBackupFolder(url) else {
            return names.lazy.map { url.deletingLastPathComponent().appending(path: $0) }.first(where: exists)
        }
        if let m = fromManifest(url, home: home) { return m }
        for n in names { if let r = rule(n, home: home, projects: projects), exists(r) { return r } }
        for n in names {
            let hits = (index[n] ?? []).filter { !inBackupFolder($0) && exists($0) }
            if hits.count == 1 { return hits[0] }
            if hits.count > 1 { return nil }   // ambiguous
        }
        return nil
    }

    /// A MANIFEST*/README* in the backup folder with a line naming this file and an absolute or ~ path.
    static func fromManifest(_ url: URL, home: URL) -> URL? {
        let pathRE = try! NSRegularExpression(pattern: #"(~/|/)[^\s"'`,()<>]+"#)
        for f in children(url.deletingLastPathComponent()) where ["manifest", "readme"].contains(where: { f.lastPathComponent.lowercased().hasPrefix($0) }) {
            for line in (readText(f) ?? "").split(whereSeparator: \.isNewline) where line.contains(url.lastPathComponent) {
                let l = String(line), ns = l as NSString
                for m in pathRE.matches(in: l, range: NSRange(location: 0, length: ns.length)) {
                    var p = ns.substring(with: m.range)
                    if p.hasPrefix("~/") { p = home.path + p.dropFirst(1) }
                    let u = URL(filePath: p)
                    if u.lastPathComponent != url.lastPathComponent, exists(u) { return u }
                }
            }
        }
        return nil
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
