import Foundation

/// `claude-config search`: ranked search over installed skills, local marketplace copies and the cached community lists.
public enum SkillSearch {
    public struct Hit: Codable, Equatable, Sendable {
        public let kind: String          // "installed", "plugin" or "community"
        public let name: String
        public let description: String
        public let source: String        // agents for installed, marketplace or repo otherwise
        public let location: String?     // installed: SKILL.md path
        public let install: String?      // available: exact install command or copy path
        public let score: Int
    }

    public struct Args: Equatable, Sendable {
        public var query = "", json = false, limit = 10
    }
    public struct UsageError: Error, Equatable { public let message: String }
    public static let usage = "usage: claude-config search \"<query>\" [--json] [--limit N]"

    /// Arguments after the program name, e.g. ["search", "viral demo", "--limit", "5"].
    public static func parse(_ argv: [String]) throws(UsageError) -> Args {
        guard argv.first == "search" else { throw UsageError(message: usage) }
        var a = Args(), words: [String] = [], it = argv.dropFirst().makeIterator()
        while let w = it.next() {
            switch w {
            case "--json": a.json = true
            case "--limit":
                guard let n = it.next().flatMap(Int.init), n > 0 else { throw UsageError(message: "--limit needs a positive number") }
                a.limit = n
            case _ where w.hasPrefix("--"): throw UsageError(message: "unknown option \(w)\n\(usage)")
            default: words.append(w)
            }
        }
        a.query = words.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard !a.query.isEmpty else { throw UsageError(message: usage) }
        return a
    }

    /// Every query word scores 3 in the name, 1 in the description; items matching no word are dropped. Installed wins ties.
    public static func rank(_ query: String, installed: [Component], available: [AvailablePlugin], community: [CommunitySkill], limit: Int) -> [Hit] {
        let words = query.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count > 1 }
        func score(_ name: String, _ desc: String) -> Int {
            let n = name.lowercased(), d = desc.lowercased()
            return words.reduce(0) { $0 + (n.contains($1) ? 3 : 0) + (d.contains($1) ? 1 : 0) }
        }
        let installedPlugins = Set(available.filter(\.installed).map(\.id))
        var hits: [Hit] = installed.map {
            Hit(kind: "installed", name: $0.name, description: $0.description,
                source: $0.agents.map(\.rawValue).joined(separator: ", "), location: $0.file.path, install: nil,
                score: score($0.name, $0.description))
        }
        hits += available.filter { !$0.installed && !installedPlugins.contains($0.id) }.map {
            Hit(kind: "plugin", name: $0.name, description: $0.description, source: $0.marketplace, location: nil,
                install: "/plugin install \($0.name)@\($0.marketplace)", score: score($0.name, $0.description))
        }
        hits += community.map { c in
            let cmd = c.marketplace
                ? "/plugin marketplace add \(c.slug) && /plugin install \(c.name)"
                : "copy \(c.link.absoluteString) -> ~/.claude/skills/\(c.path.map { ($0 as NSString).lastPathComponent } ?? c.name)/"
            return Hit(kind: "community", name: c.name, description: c.description, source: c.slug, location: nil,
                       install: cmd, score: score(c.name, c.description + " " + c.category))
        }
        let order = ["installed": 0, "plugin": 1, "community": 2]
        return Array(hits.filter { $0.score > 0 }
            .sorted { ($0.score, -order[$1.kind]!) > ($1.score, -order[$0.kind]!) }
            .prefix(limit))
    }

    public static func format(_ hits: [Hit], json: Bool) -> String {
        if json {
            let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            return String(decoding: (try? e.encode(hits)) ?? Data("[]".utf8), as: UTF8.self)
        }
        if hits.isEmpty { return "No matches." }
        return hits.enumerated().map { i, h in
            let desc = h.description.count > 100 ? String(h.description.prefix(99)) + "…" : h.description
            let where_ = h.kind == "installed" ? "agents: \(h.source)\n   at: \(h.location ?? "")" : "from: \(h.source)\n   install: \(h.install ?? "")"
            return "\(i + 1). [\(h.kind)] \(h.name)\n   \(desc)\n   \(where_)"
        }.joined(separator: "\n")
    }

    // MARK: Offline catalogs

    /// Installed personal, project-less plugin and other-agent skills, read from disk (no `claude` process).
    public static func installedSkills() -> [Component] {
        let reg = readJSON(Paths.claudeDir.appending(path: "plugins/installed_plugins.json"))?["plugins"] as? JSON ?? [:]
        let enabled = readJSON(Paths.userSettings)?["enabledPlugins"] as? JSON ?? [:]
        let plugins = reg.compactMap { id, v -> Plugin? in
            guard enabled[id] as? Bool == true, let path = (v as? [JSON])?.first(where: { $0["scope"] as? String == "user" })?["installPath"] as? String
            else { return nil }
            return Plugin(id: id, version: "", scope: "user", enabled: true, installPath: URL(filePath: path), notes: [])
        }
        return Scanner.components(projectPaths: [], plugins: plugins, usage: [:]).filter { $0.kind == .skill }
    }

    /// Plugins in each added marketplace's local clone.
    public static func localAvailable() -> [AvailablePlugin] {
        let installed = Set((readJSON(Paths.claudeDir.appending(path: "plugins/installed_plugins.json"))?["plugins"] as? JSON ?? [:]).keys)
        return children(Paths.claudeDir.appending(path: "plugins/marketplaces")).flatMap { dir -> [AvailablePlugin] in
            let m = readJSON(dir.appending(path: ".claude-plugin/marketplace.json"))
            let market = m?["name"] as? String ?? dir.lastPathComponent
            return (m?["plugins"] as? [JSON] ?? []).compactMap { p in
                guard let name = p["name"] as? String else { return nil }
                let id = "\(name)@\(market)"
                return AvailablePlugin(id: id, name: name, description: p["description"] as? String ?? "", marketplace: market,
                                       installCount: 0, installed: installed.contains(id))
            }
        }
    }

    /// The app's cached community lists; a list with no cache is fetched once and cached.
    public static func community() async -> [CommunitySkill] {
        let dir = Paths.claudeDir.appending(path: "config-editor-community")
        let lists = await withTaskGroup(of: (CommunityList, [CommunitySkill]).self) { group in
            for list in CommunityList.allCases {
                group.addTask {
                    let cache = dir.appending(path: list.rawValue)
                    if let rows = (try? Data(contentsOf: cache)).flatMap(list.parse) { return (list, rows) }
                    guard let (data, resp) = try? await URLSession.shared.data(from: list.url),
                          (resp as? HTTPURLResponse)?.statusCode == 200, let rows = list.parse(data) else { return (list, []) }
                    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    try? data.write(to: cache, options: .atomic)
                    return (list, rows)
                }
            }
            var out: [CommunityList: [CommunitySkill]] = [:]
            for await (l, rows) in group { out[l] = rows }
            return out
        }
        return CommunityCatalog.merge(CommunityList.allCases.map { lists[$0] ?? [] })
    }
}
