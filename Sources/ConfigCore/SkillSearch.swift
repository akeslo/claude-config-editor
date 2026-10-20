import Foundation

/// `claude-config search`: ranked search over installed skills and local marketplace copies.
public enum SkillSearch {
    public struct Hit: Codable, Equatable, Sendable {
        public let kind: String          // "installed", or "plugin"
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
    public static func rank(_ query: String, installed: [Component], available: [AvailablePlugin], limit: Int) -> [Hit] {
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
        let order = ["installed": 0, "plugin": 1]
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
        // Marketplace names and descriptions come from remote repos: drop control chars so ESC sequences can't drive the terminal.
        func clean(_ s: String?) -> String { String(String.UnicodeScalarView((s ?? "").unicodeScalars.map { $0.properties.generalCategory == .control ? "\u{FFFD}" : $0 })) }
        return hits.enumerated().map { i, h in
            let d = clean(h.description)
            let desc = d.count > 100 ? String(d.prefix(99)) + "…" : d
            let where_ = h.kind == "installed" ? "agents: \(clean(h.source))\n   at: \(clean(h.location))" : "from: \(clean(h.source))\n   install: \(clean(h.install))"
            return "\(i + 1). [\(h.kind)] \(clean(h.name))\n   \(desc)\n   \(where_)"
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
}
