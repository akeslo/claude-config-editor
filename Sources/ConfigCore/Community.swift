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
