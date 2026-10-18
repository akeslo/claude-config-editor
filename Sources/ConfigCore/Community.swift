import Foundation

public struct CommunitySkill: Identifiable, Sendable, Hashable {
    public let id: String
    public let name: String
    public let description: String
    public let category: String
    public let stars: Int?
    public let slug: String
    public let path: String?
    public let list: String
    public let marketplace: Bool
    public let link: URL

    /// Marketplace rows share one repo, so they are keyed by plugin name instead of path.
    init(name: String, description: String, category: String, stars: Int? = nil, slug: String, path: String?,
         list: CommunityList, marketplace: Bool = false) {
        self.name = name; self.description = description; self.category = category; self.stars = stars
        self.slug = slug; self.path = path; self.list = list.rawValue; self.marketplace = marketplace
        id = marketplace ? "\(slug)#\(name)" : slug + (path.map { "/" + $0 } ?? "")
        link = URL(string: "https://github.com/\(slug)" + (path.map { "/tree/HEAD/" + $0 } ?? ""))
            ?? URL(string: "https://github.com")!
    }
}

/// `owner/repo` plus an optional skill folder, from a github.com repo, tree or blob URL.
public func githubRef(_ url: String) -> (slug: String, path: String?)? {
    guard let u = URLComponents(string: url.trimmingCharacters(in: .whitespaces)),
          ["http", "https"].contains(u.scheme), ["github.com", "www.github.com"].contains(u.host?.lowercased()) else { return nil }
    let p = u.path.split(separator: "/").map(String.init)
    guard p.count >= 2, !p[0].isEmpty, !p[1].isEmpty else { return nil }
    var rest: [String] = []
    if p.count > 4, p[2] == "tree" || p[2] == "blob" { rest = Array(p[4...]) }
    if rest.last == "SKILL.md" { rest.removeLast() }
    return ("\(p[0])/\(p[1])", rest.isEmpty ? nil : rest.joined(separator: "/"))
}

public enum CommunityList: String, CaseIterable, Sendable {
    case video, anthropic, awesomeClaudeCode = "awesome-claude-code", composio

    public var url: URL {
        switch self {
        case .video: URL(string: "https://raw.githubusercontent.com/zhuyansen/awesome-claude-video-skills/main/data/skills.json")!
        case .anthropic: URL(string: "https://raw.githubusercontent.com/anthropics/skills/main/.claude-plugin/marketplace.json")!
        case .awesomeClaudeCode: URL(string: "https://raw.githubusercontent.com/hesreallyhim/awesome-claude-code/main/THE_RESOURCES_TABLE_NEW.csv")!
        case .composio: URL(string: "https://raw.githubusercontent.com/ComposioHQ/awesome-claude-skills/master/README.md")!
        }
    }

    public var title: String {
        switch self {
        case .video: "Video skills"
        case .anthropic: "Anthropic skills"
        case .awesomeClaudeCode: "Awesome Claude Code"
        case .composio: "Awesome Claude Skills"
        }
    }

    /// nil when the data is unusable (not the expected format, or no rows).
    public func parse(_ data: Data) -> [CommunitySkill]? {
        let rows: [CommunitySkill]?
        switch self {
        case .video: rows = parseVideo(data)
        case .anthropic: rows = parseAnthropic(data)
        case .awesomeClaudeCode: rows = parseCSV(data)
        case .composio: rows = parseReadme(data)
        }
        return rows?.isEmpty == false ? rows : nil
    }

    private func parseVideo(_ data: Data) -> [CommunitySkill]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? JSON,
              let items = root["skills"] as? [JSON] else { return nil }
        var labels: [String: String] = [:]
        for k in root["kinds"] as? [JSON] ?? [] {
            if let id = k["id"] as? String, let en = k["en"] as? String { labels[id] = [k["icon"] as? String, en].compactMap { $0 }.joined(separator: " ") }
        }
        return items.compactMap { s in
            guard let repo = s["repo_full_name"] as? String, let ref = githubRef("https://github.com/" + repo) else { return nil }
            let kind = s["kind"] as? String ?? ""
            let path = (s["path"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return CommunitySkill(name: ref.slug.split(separator: "/").last.map(String.init) ?? ref.slug,
                                  description: s["description"] as? String ?? "", category: labels[kind] ?? kind,
                                  stars: s["stars"] as? Int, slug: ref.slug, path: path, list: self)
        }
    }

    private func parseAnthropic(_ data: Data) -> [CommunitySkill]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? JSON,
              let plugins = root["plugins"] as? [JSON] else { return nil }
        return plugins.compactMap { p in
            guard let name = p["name"] as? String, !name.isEmpty else { return nil }
            return CommunitySkill(name: name, description: p["description"] as? String ?? "", category: "Anthropic",
                                  slug: "anthropics/skills", path: nil, list: self, marketplace: true)
        }
    }

    private func parseCSV(_ data: Data) -> [CommunitySkill]? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let table = csvRows(text)
        guard let head = table.first, let iLink = head.firstIndex(of: "Link"), let iName = head.firstIndex(of: "Display Name") else { return nil }
        let iCat = head.firstIndex(of: "Category"), iDesc = head.firstIndex(of: "Description"), iStale = head.firstIndex(of: "Stale")
        func cell(_ r: [String], _ i: Int?) -> String { i.flatMap { $0 < r.count ? r[$0] : nil } ?? "" }
        return table.dropFirst().compactMap { r in
            guard cell(r, iStale).lowercased() != "true", let ref = githubRef(cell(r, iLink)), !cell(r, iName).isEmpty else { return nil }
            return CommunitySkill(name: cell(r, iName), description: cell(r, iDesc), category: cell(r, iCat),
                                  slug: ref.slug, path: ref.path, list: self)
        }
    }

    private func parseReadme(_ data: Data) -> [CommunitySkill]? {
        guard let text = String(data: data, encoding: .utf8),
              let bullet = try? NSRegularExpression(pattern: #"^\s*[-*] \*{0,2}\[([^\]]+)\]\((https?://[^)]+)\)\*{0,2}\s*[-–:]\s*(.+)$"#) else { return nil }
        var category = ""
        var out: [CommunitySkill] = []
        for line in text.split(whereSeparator: \.isNewline).map(String.init) {
            if line.hasPrefix("## ") || line.hasPrefix("### ") {
                category = line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
                continue
            }
            let ns = line as NSString
            guard let m = bullet.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)),
                  let ref = githubRef(ns.substring(with: m.range(at: 2))) else { continue }
            out.append(CommunitySkill(name: ns.substring(with: m.range(at: 1)),
                                      description: ns.substring(with: m.range(at: 3)).trimmingCharacters(in: .whitespaces),
                                      category: category, slug: ref.slug, path: ref.path, list: self))
        }
        return out
    }
}

/// RFC 4180: quoted fields may hold commas, newlines and doubled quotes.
func csvRows(_ text: String) -> [[String]] {
    var rows: [[String]] = [], row: [String] = [], field = ""
    var quoted = false, pending = false  // pending: a field/row has started
    var it = text.makeIterator()
    var next = it.next()
    while let c = next {
        next = it.next()
        if quoted {
            if c == "\"" { if next == "\"" { field.append("\""); next = it.next() } else { quoted = false } }
            else { field.append(c) }
        } else if c == "\"" { quoted = true; pending = true }
        else if c == "," { row.append(field); field = ""; pending = true }
        else if c == "\n" || c == "\r\n" || c == "\r" {
            if pending || !field.isEmpty { row.append(field); rows.append(row) }
            row = []; field = ""; pending = false
        } else { field.append(c); pending = true }
    }
    if pending || !field.isEmpty { row.append(field); rows.append(row) }
    return rows
}

public enum CommunityCatalog {
    /// Dedupe by id, keeping the first.
    public static func merge(_ lists: [[CommunitySkill]]) -> [CommunitySkill] {
        var seen = Set<String>()
        return lists.joined().filter { seen.insert($0.id).inserted }
    }
}

// MARK: - Download, find, install

public struct FoundSkill: Sendable, Hashable {
    public let name: String
    public let dir: URL
    /// Paths relative to `dir`.
    public let files: [String]
    public let scripts: [String]
}

public struct SkillCopy: Sendable, Hashable {
    public let from: URL
    public let name: String
    /// Where the skill came from, shown in the install preview.
    public let link: URL?
    public init(from: URL, name: String, link: URL? = nil) { self.from = from; self.name = name; self.link = link }
}

public struct CommunityError: LocalizedError, Sendable {
    public let errorDescription: String?
    init(_ m: String) { errorDescription = m }
}

/// `[A-Za-z0-9._-]` only, and never `.`/`..` (which would escape the skills dir); nil when nothing usable is left.
func skillName(_ raw: String) -> String? {
    let s = String(raw.unicodeScalars.filter { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-").contains($0) })
    return s.isEmpty || s.allSatisfy({ $0 == "." }) ? nil : s
}

/// Downloads `owner/repo` at HEAD and returns its extracted root (a fresh dir; its parent temp dir is the caller's to delete).
public func downloadRepo(_ slug: String) async throws -> URL {
    guard slug.wholeMatch(of: /[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+/) != nil,
          !slug.split(separator: "/").contains(where: { $0.allSatisfy { $0 == "." } }),
          let url = URL(string: "https://codeload.github.com/\(slug)/tar.gz/HEAD") else { throw CommunityError("Not a GitHub repo: \(slug)") }
    let cap = 50 * 1024 * 1024
    let fm = FileManager.default
    let tmp = fm.temporaryDirectory.appending(path: "config-editor-repo-\(UUID().uuidString)")
    try fm.createDirectory(at: tmp, withIntermediateDirectories: false)
    do {
        let (bytes, response) = try await URLSession.shared.bytes(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw CommunityError("Couldn't download \(slug).") }
        if response.expectedContentLength > cap { throw CommunityError("\(slug) is over 50 MB.") }
        var data = Data()
        for try await b in bytes {
            data.append(b)
            if data.count > cap { throw CommunityError("\(slug) is over 50 MB.") }
        }
        let tarball = tmp.appending(path: "repo.tar.gz")
        try data.write(to: tarball)
        let root = tmp.appending(path: "src")
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        try await extractTarball(tarball, into: root)
        try? fm.removeItem(at: tarball)
        return root
    } catch {
        try? fm.removeItem(at: tmp)
        throw error
    }
}

/// On-disk size and entry count under `dir`, not following symlinks.
private func usage(_ dir: URL) -> (bytes: Int, entries: Int) {
    var bytes = 0, entries = 0
    for case let f as URL in FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) ?? .init() {
        entries += 1
        bytes += (try? f.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0
    }
    return (bytes, entries)
}

/// Extracts into `dir` (dropping codeload's `<repo>-<sha>/` top folder) under a watchdog that stops tar
/// once the unpacked tree exceeds `maxBytes` or `maxEntries`, or after `timeout` seconds; on any failure
/// `dir` is deleted. bsdtar refuses `..` and absolute member paths by default.
func extractTarball(_ tarball: URL, into dir: URL, maxBytes: Int = 200 * 1024 * 1024, maxEntries: Int = 20_000,
                    timeout: TimeInterval = 60) async throws {
    let p = Process()
    p.executableURL = URL(filePath: "/usr/bin/tar")
    p.arguments = ["-xzf", tarball.path, "-C", dir.path, "--strip-components", "1"]
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    func check() throws {
        let u = usage(dir)
        if u.bytes > maxBytes { throw CommunityError("The repo is over 200 MB unpacked.") }
        if u.entries > maxEntries { throw CommunityError("The repo has too many files.") }
    }
    do {
        try p.run()
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning {
            if Date() > deadline { throw CommunityError("Unpacking took too long.") }
            try check()
            try await Task.sleep(for: .milliseconds(250))
        }
        guard p.terminationStatus == 0 else { throw CommunityError("Couldn't unpack the repo.") }
        try check()
    } catch {
        if p.isRunning { p.terminate(); p.waitUntilExit() }
        try? FileManager.default.removeItem(at: dir)
        throw error
    }
}

private let scriptExtensions: Set<String> = ["sh", "py", "js", "ts", "rb", "pl", "ps1", "bash", "zsh", "mjs", "cjs"]

/// Every folder under `root` holding a `SKILL.md`. Symlinked folders are not followed.
/// `fallbackName` names a nameless skill at `root` itself (e.g. the repo name, since the extract dir is `src`).
public func findSkills(in root: URL, fallbackName: String? = nil) -> [FoundSkill] {
    let fm = FileManager.default
    guard let e = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
    var out: [FoundSkill] = []
    for case let f as URL in e where f.lastPathComponent == "SKILL.md" {
        guard (try? f.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
        let dir = f.deletingLastPathComponent()
        guard let name = Frontmatter(readText(f) ?? "").values["name"].flatMap(skillName) ?? skillName(dir.standardizedFileURL == root.standardizedFileURL ? fallbackName ?? dir.lastPathComponent : dir.lastPathComponent) else { continue }
        var files: [String] = [], scripts: [String] = []
        let base = dir.standardizedFileURL.path + "/"
        for case let g as URL in fm.enumerator(at: dir, includingPropertiesForKeys: [.isDirectoryKey]) ?? .init() {
            guard let attrs = try? fm.attributesOfItem(atPath: g.path), attrs[.type] as? FileAttributeType != .typeDirectory else { continue }
            let rel = String(g.standardizedFileURL.path.dropFirst(base.count))
            files.append(rel)
            let exec = ((attrs[.posixPermissions] as? Int) ?? 0) & 0o111 != 0
            if exec || scriptExtensions.contains(g.pathExtension.lowercased()) { scripts.append(rel) }
        }
        out.append(FoundSkill(name: name, dir: dir, files: files.sorted(), scripts: scripts.sorted()))
    }
    return out
}

public func hasMarketplace(_ root: URL) -> Bool {
    FileManager.default.fileExists(atPath: root.appending(path: ".claude-plugin/marketplace.json").path)
}

/// Copies a skill folder to `skillsDir/<name>`. Returns false (and touches nothing) when that name already exists.
/// Symlinks are copied as the file they point to, and refused unless that file lies inside `c.from`.
public func installSkill(_ c: SkillCopy, into skillsDir: URL = Paths.claudeDir.appending(path: "skills")) throws -> Bool {
    guard skillName(c.name) == c.name else { throw CommunityError("Invalid skill name: \(c.name)") }
    let fm = FileManager.default
    let target = skillsDir.appending(path: c.name)
    if (try? fm.attributesOfItem(atPath: target.path)) != nil { return false }
    let src = c.from.resolvingSymlinksInPath().standardizedFileURL
    let base = src.path + "/"
    // Plan the whole copy first so a refused symlink leaves nothing behind.
    var plan: [(rel: String, from: URL?)] = []  // nil `from` = directory
    guard let e = fm.enumerator(at: src, includingPropertiesForKeys: nil) else { throw CommunityError("Can't read \(c.from.path)") }
    for case let f as URL in e {
        let rel = String(f.standardizedFileURL.path.dropFirst(base.count))
        let type = try fm.attributesOfItem(atPath: f.path)[.type] as? FileAttributeType
        switch type {
        case .typeDirectory: plan.append((rel, nil))
        case .typeRegular: plan.append((rel, f))
        case .typeSymbolicLink:
            let real = f.resolvingSymlinksInPath().standardizedFileURL
            var isDir: ObjCBool = false
            guard real.path.hasPrefix(base), fm.fileExists(atPath: real.path, isDirectory: &isDir), !isDir.boolValue else {
                throw CommunityError("Refusing \(rel): it links outside the skill folder.")
            }
            plan.append((rel, real))
        default: throw CommunityError("Refusing \(rel): not a regular file.")
        }
    }
    try fm.createDirectory(at: skillsDir, withIntermediateDirectories: true)
    try fm.createDirectory(at: target, withIntermediateDirectories: false)
    do {
        for p in plan {
            let to = target.appending(path: p.rel)
            if let from = p.from { try fm.copyItem(at: from, to: to) } // copyItem keeps permissions
            else { try fm.createDirectory(at: to, withIntermediateDirectories: true) }
        }
    } catch {
        try? fm.removeItem(at: target)
        throw error
    }
    return true
}
