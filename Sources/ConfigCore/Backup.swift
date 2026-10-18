import Foundation

/// Delete-with-undo and pre-write snapshots, kept under `~/.claude/backups/config-editor/<yyyyMMdd-HHmmss>/<path relative to home>`.
/// Every call takes `home` so tests can use a temp dir; the app uses `Paths.home`.
public enum Backup {
    public struct Record: Sendable, Hashable, Identifiable {
        /// Where the item lived.
        public let original: URL
        /// Its copy inside the backup folder.
        public let copy: URL
        public let date: Date
        /// true when the original was removed (trash), false for a snapshot taken before a write.
        public let removed: Bool
        public var id: URL { copy }
    }

    public enum BackupError: LocalizedError {
        case outsideHome(String), missing(String), refused(String)
        public var errorDescription: String? {
            switch self {
            case .outsideHome(let p): "\(p) is outside the home folder, so it cannot be backed up."
            case .missing(let p): "\(p) does not exist."
            case .refused(let why): "Refused: \(why)."
            }
        }
    }

    public static func root(home: URL = Paths.home) -> URL { home.appending(path: ".claude/backups/config-editor") }

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()

    static func relative(_ url: URL, home: URL) throws -> String {
        let h = home.standardizedFileURL.path, p = url.standardizedFileURL.path
        guard p.hasPrefix(h + "/") else { throw BackupError.outsideHome(p) }
        return String(p.dropFirst(h.count + 1))
    }

    /// Copies `url` into a fresh timestamped backup folder (a counter keeps same-second copies apart).
    static func copyIn(_ url: URL, home: URL, now: Date) throws -> URL {
        let fm = FileManager.default
        guard exists(url) else { throw BackupError.missing(url.path) }
        let rel = try relative(url, home: home)
        var dir = root(home: home).appending(path: stamp.string(from: now))
        var n = 1
        while exists(dir.appending(path: rel)) { n += 1; dir = root(home: home).appending(path: "\(stamp.string(from: now))-\(n)") }
        let copy = dir.appending(path: rel)
        try fm.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.copyItem(at: url, to: copy)
        return copy
    }

    /// Backs up `url`, then removes it. Refuses live config and working folders (`trashRefusal`).
    @discardableResult
    public static func trash(_ url: URL, home: URL = Paths.home, now: Date = Date()) throws -> Record {
        if let why = trashRefusal(url) { throw BackupError.refused(why) }
        let copy = try copyIn(url, home: home, now: now)
        try FileManager.default.removeItem(at: url)
        return Record(original: url, copy: copy, date: now, removed: true)
    }

    /// Copies `url` aside before a write; the original stays.
    @discardableResult
    public static func snapshot(_ url: URL, home: URL = Paths.home, now: Date = Date()) throws -> Record {
        Record(original: url, copy: try copyIn(url, home: home, now: now), date: now, removed: false)
    }

    /// Puts the backed-up copy back at its original path, replacing whatever is there now. The backup is kept.
    public static func restore(_ r: Record) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: r.original.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmp = r.original.deletingLastPathComponent().appending(path: ".\(r.original.lastPathComponent).restore-\(UUID().uuidString)")
        try fm.copyItem(at: r.copy, to: tmp)
        if exists(r.original) { _ = try fm.replaceItemAt(r.original, withItemAt: tmp) } else { try fm.moveItem(at: tmp, to: r.original) }
    }

    /// Every backed-up item, newest first. `removed` is inferred: the original no longer exists.
    public static func list(home: URL = Paths.home) -> [Record] {
        children(root(home: home)).flatMap { dir -> [Record] in
            let date = stamp.date(from: String(dir.lastPathComponent.prefix(15))) ?? modificationDate(dir) ?? .distantPast
            return leaves(dir, rel: "").map { rel in
                let original = home.appending(path: rel)
                return Record(original: original, copy: dir.appending(path: rel), date: date, removed: !exists(original))
            }
        }
        .sorted { $0.date > $1.date }
    }

    /// Relative paths of backed-up items: files, plus directories whose name looks like a backed-up folder (descended into otherwise).
    /// shortcut: a trashed folder is listed as its files, not as one item; fine for undo-by-record, upgrade if a UI lists folder backups.
    private static func leaves(_ dir: URL, rel: String) -> [String] {
        children(dir).flatMap { c -> [String] in
            let r = rel.isEmpty ? c.lastPathComponent : rel + "/" + c.lastPathComponent
            let isDir = (try? c.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            return isDir ? leaves(c, rel: r) : [r]
        }
    }
}
