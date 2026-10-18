import Foundation

/// Structured picks Ask Claude appends to a Discover answer as a fenced JSON block, matched against the loaded catalog.
public enum Recommendations {
    public struct Pick: Decodable, Equatable, Sendable {
        public let kind: String, name: String, marketplace: String?, reason: String?
    }
    public enum Item: Identifiable, Sendable {
        case plugin(AvailablePlugin, reason: String)
        case community(CommunitySkill, reason: String)
        public var id: String {
            switch self { case .plugin(let p, _): "p:" + p.id; case .community(let s, _): "c:" + s.id }
        }
    }

    public static let instruction = """
        After your answer, if you recommend installing anything listed on this screen, end with exactly one fenced block:
        ```json
        [{"kind": "plugin" or "community", "name": "<exact name from the list>", "marketplace": "<marketplace, plugins only>", "reason": "<one short line>"}]
        ```
        Only use names that appear in the Marketplace plugins or Community skills lists above. Omit the block if you recommend nothing.
        """

    /// Splits the last ```json fenced block off `text`. A missing or unparsable block returns the text unchanged and no picks.
    public static func parse(_ text: String) -> (prose: String, picks: [Pick]) {
        guard let open = text.range(of: "```json", options: .backwards),
              let close = text.range(of: "```", range: open.upperBound..<text.endIndex),
              let picks = try? JSONDecoder().decode([Pick].self, from: Data(text[open.upperBound..<close.lowerBound].utf8))
        else { return (text, []) }
        let prose = (text[..<open.lowerBound] + text[close.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return (prose, picks)
    }

    /// Keeps only picks naming a real catalog row (case-insensitive; marketplace narrows plugins when given), deduplicated.
    public static func match(_ picks: [Pick], available: [AvailablePlugin], community: [CommunitySkill]) -> [Item] {
        var seen = Set<String>(), out: [Item] = []
        for p in picks {
            let n = p.name.lowercased(), reason = p.reason ?? ""
            let item: Item?
            if p.kind == "community" {
                item = community.first { $0.name.lowercased() == n }.map { .community($0, reason: reason) }
            } else {
                let byName = available.filter { $0.name.lowercased() == n || $0.id.lowercased() == n }
                let m = p.marketplace?.lowercased()
                item = (byName.first { $0.marketplace.lowercased() == m } ?? byName.first).map { .plugin($0, reason: reason) }
            }
            if let item, seen.insert(item.id).inserted { out.append(item) }
        }
        return out
    }
}

extension Recommendations {
    /// Menu bar quick search over the loaded catalog: name hits first, then description hits, capped. Local only, no I/O.
    public static func search(_ query: String, available: [AvailablePlugin], community: [CommunitySkill], cap: Int = 20) -> [Item] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        let all: [(Item, String, String)] = available.map { (.plugin($0, reason: $0.description), $0.name, $0.description) }
            + community.map { (.community($0, reason: $0.description), $0.name, $0.description + " " + $0.category) }
        let named = all.filter { $0.1.localizedCaseInsensitiveContains(q) }
        let described = all.filter { !$0.1.localizedCaseInsensitiveContains(q) && $0.2.localizedCaseInsensitiveContains(q) }
        return (named + described).prefix(cap).map(\.0)
    }
}
