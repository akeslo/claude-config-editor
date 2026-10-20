import Foundation

public enum WriteError: LocalizedError, Equatable {
    case unparseable(URL), changedOnDisk(URL), outsideKnownPaths(URL), backupFailed(URL)
    public var errorDescription: String? {
        switch self {
        case .unparseable(let u): "\(shortPath(u)) can't be read as JSON (corrupt, or being written right now). Nothing was changed."
        case .changedOnDisk(let u): "\(shortPath(u)) changed on disk since it was read. Reload and try again."
        case .outsideKnownPaths(let u): "\(shortPath(u)) is not a config file this app manages, so it was not written."
        case .backupFailed(let u): "Couldn't back up \(shortPath(u)), so nothing was changed."
        }
    }
}

/// The one writer for every config file: ownership check, mtime check, backup, unique temp file, original mode kept.
public enum ConfigWriter {
    /// Edits a JSON object file. An existing file that won't parse is refused untouched. Returns the backup (nil for a new file).
    @discardableResult
    public static func mutateJSON(_ url: URL, provider: any Provider, home: URL, projects: [URL], expectedModified: Date?,
                                  _ edit: (inout [String: Any]) throws -> Void) throws -> URL? {
        // Write through symlinks (dotfile setups): check, back up and replace the real file, so the link stays.
        let url = url.resolvingSymlinksInPath()
        try guardWrite(url, provider: provider, home: home, projects: projects, expectedModified: expectedModified)
        var root: JSON = [:], shape: Shape?, trailingNewline = true
        if exists(url) {
            guard let data = try? Data(contentsOf: url), let obj = (try? JSONSerialization.jsonObject(with: data)) as? JSON else { throw WriteError.unparseable(url) }
            root = obj
            var reader = ShapeReader(b: Array(data))
            shape = reader.value()
            trailingNewline = data.last == 0x0A
        }
        try edit(&root)
        let text = try render(root, shape, "") + (trailingNewline ? "\n" : "")
        let backup = try backUp(url, provider: provider, home: home)
        try commit(Data(text.utf8), to: url)
        return backup
    }

    /// Replaces a whole text file (Markdown, TOML, ...). Returns the backup (nil for a new file).
    @discardableResult
    public static func writeText(_ text: String, to url: URL, provider: any Provider, home: URL, projects: [URL], expectedModified: Date?) throws -> URL? {
        // Write through symlinks (dotfile setups): check, back up and replace the real file, so the link stays.
        let url = url.resolvingSymlinksInPath()
        try guardWrite(url, provider: provider, home: home, projects: projects, expectedModified: expectedModified)
        let backup = try backUp(url, provider: provider, home: home)
        try commit(Data(text.utf8), to: url)
        return backup
    }

    /// The provider owning `url`, treating each ancestor folder as a possible project.
    /// shortcut: ownership is by path shape (a `.claude/` dir, `AGENTS.md`, ...), not the scanned project list; pass real `projects` once callers have them.
    public static func owner(of url: URL, home: URL) -> (provider: any Provider, projects: [URL])? {
        let projects = ancestors(url)
        return ProviderRegistry.all.first { owns($0, url, home: home, projects: projects) }.map { ($0, projects) }
    }

    /// `mutateJSON` for callers that only know the file.
    @discardableResult
    public static func mutateJSON(_ url: URL, home: URL, expectedModified: Date?, _ edit: (inout [String: Any]) throws -> Void) throws -> URL? {
        guard let o = owner(of: url, home: home) else { throw WriteError.outsideKnownPaths(url) }
        return try mutateJSON(url, provider: o.provider, home: home, projects: o.projects, expectedModified: expectedModified, edit)
    }

    /// `writeText` for callers that only know the file.
    @discardableResult
    public static func writeText(_ text: String, to url: URL, home: URL, expectedModified: Date?) throws -> URL? {
        guard let o = owner(of: url, home: home) else { throw WriteError.outsideKnownPaths(url) }
        return try writeText(text, to: url, provider: o.provider, home: home, projects: o.projects, expectedModified: expectedModified)
    }

    // MARK: Steps

    static func ancestors(_ url: URL) -> [URL] {
        var out: [URL] = [], u = url.standardizedFileURL.deletingLastPathComponent()
        while u.path != "/" { out.append(u); u = u.deletingLastPathComponent() }
        return out
    }

    static func owns(_ p: any Provider, _ url: URL, home: URL, projects: [URL]) -> Bool {
        let path = url.standardizedFileURL.path
        return p.ownedPaths(home: home, projects: projects).contains { let o = $0.standardizedFileURL.path; return path == o || path.hasPrefix(o + "/") }
    }

    static func guardWrite(_ url: URL, provider: any Provider, home: URL, projects: [URL], expectedModified: Date?) throws {
        guard owns(provider, url, home: home, projects: projects) else { throw WriteError.outsideKnownPaths(url) }
        if let e = expectedModified, exists(url), modificationDate(url) != e { throw WriteError.changedOnDisk(url) }
    }

    /// Copy under `<home>/.claude/config-editor-backups/<provider>/<stamp>/<path>`.
    static func backUp(_ url: URL, provider: any Provider, home: URL) throws -> URL? {
        guard exists(url) else { return nil }
        do { return try Backup.copyIn(url, home: home, now: Date(), root: Backup.appBackups(home).appending(path: provider.id.rawValue)) }
        catch { throw WriteError.backupFailed(url) }
    }

    static func commit(_ data: Data, to url: URL) throws {
        let fm = FileManager.default
        let mode = (try? fm.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) ?? 0o600
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmp = url.deletingLastPathComponent().appending(path: ".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        guard fm.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: mode]) else {
            try? fm.removeItem(at: tmp)
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: tmp.path])
        }
        do {
            if exists(url) { _ = try fm.replaceItemAt(url, withItemAt: tmp) } else { try fm.moveItem(at: tmp, to: url) }
        } catch { try? fm.removeItem(at: tmp); throw error }
    }

    // MARK: Order-keeping JSON output (JSONSerialization loses key order)

    indirect enum Shape { case obj([String], [String: Shape]), arr([Shape]), leaf }

    /// Reads only the key order of already-validated JSON.
    struct ShapeReader {
        let b: [UInt8]
        var i = 0
        mutating func ws() { while i < b.count, [0x20, 0x0A, 0x0D, 0x09].contains(b[i]) { i += 1 } }
        mutating func string() -> String {
            let start = i
            i += 1
            while i < b.count, b[i] != 0x22 { if b[i] == 0x5C { i += 1 }; i += 1 }
            i += 1
            return (try? JSONSerialization.jsonObject(with: Data(b[start..<min(i, b.count)]), options: .fragmentsAllowed)) as? String ?? ""
        }
        mutating func value() -> Shape {
            ws()
            guard i < b.count else { return .leaf }
            switch b[i] {
            case 0x7B:  // {
                i += 1
                var keys: [String] = [], kids: [String: Shape] = [:]
                while true {
                    ws()
                    guard i < b.count, b[i] != 0x7D else { i += 1; break }
                    if b[i] == 0x2C { i += 1; continue }
                    let k = string()
                    ws(); i += 1  // :
                    let v = value()
                    if kids[k] == nil { keys.append(k) }
                    kids[k] = v
                }
                return .obj(keys, kids)
            case 0x5B:  // [
                i += 1
                var items: [Shape] = []
                while true {
                    ws()
                    guard i < b.count, b[i] != 0x5D else { i += 1; break }
                    if b[i] == 0x2C { i += 1; continue }
                    items.append(value())
                }
                return .arr(items)
            case 0x22: _ = string(); return .leaf
            default:
                while i < b.count, ![0x2C, 0x5D, 0x7D, 0x20, 0x0A, 0x0D, 0x09].contains(b[i]) { i += 1 }
                return .leaf
            }
        }
    }

    /// Two-space JSON like Claude's own files; known keys keep their order, new keys go last (sorted).
    static func render(_ v: Any, _ shape: Shape?, _ indent: String) throws -> String {
        let inner = indent + "  "
        if let d = v as? JSON {
            if d.isEmpty { return "{}" }
            var order: [String] = [], kids: [String: Shape] = [:]
            if case .obj(let k, let c) = shape { order = k; kids = c }
            let known = Set(order)
            let keys = order.filter { d[$0] != nil } + d.keys.filter { !known.contains($0) }.sorted()
            return "{\n" + (try keys.map { inner + (try scalar($0)) + ": " + (try render(d[$0]!, kids[$0], inner)) }).joined(separator: ",\n") + "\n" + indent + "}"
        }
        if let a = v as? [Any] {
            if a.isEmpty { return "[]" }
            var shapes: [Shape] = []
            if case .arr(let s) = shape { shapes = s }
            return "[\n" + (try a.enumerated().map { inner + (try render($1, $0 < shapes.count ? shapes[$0] : nil, inner)) }).joined(separator: ",\n") + "\n" + indent + "]"
        }
        return try scalar(v)
    }

    static func scalar(_ v: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: v, options: [.fragmentsAllowed, .withoutEscapingSlashes]), as: UTF8.self)
    }
}
