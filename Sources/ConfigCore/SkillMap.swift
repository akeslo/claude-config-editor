import Foundation
import CoreGraphics

// MARK: Skill map: metrics, dimensions, filters, layout and insights. Pure, so the UI only draws.

/// What a skill's size (word, block, bubble) stands for.
public enum SkillMetric: String, CaseIterable, Sendable {
    case uses = "Uses", tokens = "Tokens", recency = "Recency", agents = "Agents", fileSize = "File size"
}

/// A way to colour, group or filter skills.
public enum SkillDimension: String, CaseIterable, Sendable, Codable {
    case source = "Source", category = "Category", agent = "Agent", mode = "Mode", staleness = "Staleness"
    case plugin = "Plugin", project = "Project", usageBand = "Usage band"
}

/// Absolute bands, so a skill's band doesn't move when others change.
public enum UsageBand: String, CaseIterable, Sendable {
    case heavy = "Heavy (30+)", regular = "Regular (5–29)", rare = "Rare (1–4)", never = "Never"
    public init(uses: Int) { self = uses >= 30 ? .heavy : uses >= 5 ? .regular : uses >= 1 ? .rare : .never }
}

/// Scatter quadrants: x = always-on tokens, y = uses, split at the given thresholds.
public enum Quadrant: String, CaseIterable, Sendable {
    case expensiveUnused = "Expensive and unused: prune", expensiveUsed = "Expensive and used: worth it"
    case cheapUsed = "Cheap and used: keep", cheapUnused = "Cheap and unused: harmless"
    public init(tokens: Int, uses: Int, tokenSplit: Int, useSplit: Int) {
        let costly = tokens > tokenSplit, used = uses > useSplit
        self = costly ? (used ? .expensiveUsed : .expensiveUnused) : (used ? .cheapUsed : .cheapUnused)
    }
}

/// Everything the map needs about one skill, computed once per scan.
public struct SkillFacts: Identifiable, Sendable {
    public let skill: Component
    public let fileBytes: Int
    public let category: String
    public let freshness: String     // "Used recently" / "Stale" / "Never used"
    public let overlaps: [String]    // ids of competing skills
    public var id: String { skill.id }
    public var uses: Int { skill.usageCount }
    public var tokens: Int { skill.listingTokens }

    public func value(_ m: SkillMetric, now: Date = Date()) -> Double {
        switch m {
        case .uses: Double(uses)
        case .tokens: Double(tokens)
        // Days of the last year still ahead of the last use: used today ≈ 365, a year ago or never = 0.
        case .recency: skill.lastUsed.map { max(0, 365 - now.timeIntervalSince($0) / 86_400) } ?? 0
        case .agents: Double(skill.agents.count)
        case .fileSize: Double(fileBytes)
        }
    }

    /// Values under a dimension; agent is multi-valued, the rest have one.
    public func keys(_ d: SkillDimension) -> [String] {
        switch d {
        case .source: [Self.source(skill)]
        case .category: [category]
        case .agent: skill.agents.map(\.rawValue)
        case .mode: [Self.mode(skill.state)]
        case .staleness: [freshness]
        case .plugin: [skill.scope == .plugin ? skill.owner?.split(separator: "@").first.map(String.init) ?? "?" : "—"]
        case .project: [skill.scope == .project ? skill.owner.map { ($0 as NSString).lastPathComponent } ?? "?" : "—"]
        case .usageBand: [UsageBand(uses: uses).rawValue]
        }
    }

    public static func source(_ c: Component) -> String {
        switch c.scope { case .user: "Personal"; case .project: "Project"; case .external: "Other agent"; default: "Plugin" }
    }
    public static func mode(_ s: SkillState) -> String { s == .always ? "Automatic" : s == .onDemand ? "Call-only" : "Off" }
}

public func skillFacts(_ components: [Component], now: Date = Date(),
                       fileSize: (URL) -> Int = { (try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }) -> [SkillFacts] {
    let skills = uniqueSkills(components)
    var over: [String: Set<String>] = [:]
    for o in skillOverlaps(skills) { for s in o.skills { over[s.id, default: []].formUnion(o.skills.map(\.id).filter { $0 != s.id }) } }
    return skills.map { c in
        let fresh = c.usageCount == 0 ? "Never used"
            : Staleness.of(lastUsed: c.lastUsed ?? c.installedAt, now: now).level == .stale ? "Stale" : "Used recently"
        return SkillFacts(skill: c, fileBytes: fileSize(c.file), category: c.category, freshness: fresh, overlaps: (over[c.id] ?? []).sorted())
    }
}

/// Chip filters: AND across dimensions, OR within one; plus text search and an optional id set (from an insight).
public struct SkillFilter: Sendable, Equatable, Codable {
    public var chips: [SkillDimension: Set<String>] = [:]
    public var search = ""
    public var ids: Set<String>?
    public init() {}
    public var isEmpty: Bool { chips.values.allSatisfy(\.isEmpty) && search.isEmpty && ids == nil }

    public func matches(_ f: SkillFacts) -> Bool {
        if let ids, !ids.contains(f.id) { return false }
        for (d, vals) in chips where !vals.isEmpty && !f.keys(d).contains(where: vals.contains) { return false }
        guard !search.isEmpty else { return true }
        return [f.skill.name, f.skill.description, f.category, f.skill.belongsTo].contains { $0.localizedCaseInsensitiveContains(search) }
    }
    public mutating func toggle(_ d: SkillDimension, _ v: String) {
        if chips[d, default: []].remove(v) == nil { chips[d, default: []].insert(v) }
    }
}

/// Groups biggest first by total metric, "—"/"Other" last. A multi-valued key (agent) puts a skill in each of its groups.
public func skillGroups(_ facts: [SkillFacts], by d: SkillDimension?, metric: SkillMetric = .uses, now: Date = Date()) -> [(key: String, items: [SkillFacts])] {
    guard let d else { return facts.isEmpty ? [] : [("All", facts)] }
    var g: [String: [SkillFacts]] = [:]
    for f in facts { for k in f.keys(d) { g[k, default: []].append(f) } }
    func total(_ x: [SkillFacts]) -> Double { x.reduce(0) { $0 + $1.value(metric, now: now) } }
    let tail: Set = ["—", "Other", "?"]
    return g.map { ($0.key, $0.value) }.sorted {
        tail.contains($0.0) != tail.contains($1.0) ? tail.contains($1.0)
            : (total($0.1), $0.1.count, $1.0) > (total($1.1), $1.1.count, $0.0)
    }
}

/// Squarified treemap (Bruls et al.): rects in input order, areas proportional to values. Zero/negative values get no area.
public func squarify(_ values: [Double], in rect: CGRect) -> [CGRect] {
    var out = Array(repeating: CGRect.zero, count: values.count)
    let total = values.reduce(0) { $0 + max(0, $1) }
    guard total > 0, rect.width > 0, rect.height > 0 else { return out }
    let scale = Double(rect.width * rect.height) / total
    var order = values.indices.filter { values[$0] > 0 }.sorted { values[$0] > values[$1] }
    var free = rect
    func worst(_ row: [Int], side: Double) -> Double {
        let areas = row.map { values[$0] * scale }, s = areas.reduce(0, +)
        guard let mx = areas.max(), let mn = areas.min(), s > 0 else { return .infinity }
        return max(side * side * mx / (s * s), s * s / (side * side * mn))
    }
    while !order.isEmpty {
        let side = Double(min(free.width, free.height))
        var row = [order.removeFirst()]
        while let next = order.first, worst(row + [next], side: side) <= worst(row, side: side) { row.append(order.removeFirst()) }
        let area = row.reduce(0) { $0 + values[$1] * scale }
        let horizontal = free.width >= free.height   // lay the row along the short side
        let thick = CGFloat(area / side)
        var offset: CGFloat = 0
        for i in row {
            let len = CGFloat(values[i] * scale / area * side)
            out[i] = horizontal ? CGRect(x: free.minX, y: free.minY + offset, width: thick, height: len)
                                : CGRect(x: free.minX + offset, y: free.minY, width: len, height: thick)
            offset += len
        }
        free = horizontal ? CGRect(x: free.minX + thick, y: free.minY, width: max(0, free.width - thick), height: free.height)
                          : CGRect(x: free.minX, y: free.minY + thick, width: free.width, height: max(0, free.height - thick))
    }
    return out
}

public func median(_ xs: [Int]) -> Int {
    let s = xs.sorted()
    return s.isEmpty ? 0 : s[s.count / 2]
}

/// Links for a 3-column flow: source → category → mode, as (from, to, count) per stage.
public func skillFlows(_ facts: [SkillFacts]) -> [[(from: String, to: String, count: Int)]] {
    func stage(_ a: SkillDimension, _ b: SkillDimension) -> [(from: String, to: String, count: Int)] {
        var n: [String: Int] = [:]
        for f in facts { n[f.keys(a)[0] + "\u{1}" + f.keys(b)[0], default: 0] += 1 }
        return n.map { k, v in let p = k.split(separator: "\u{1}", omittingEmptySubsequences: false); return (String(p[0]), String(p[1]), v) }
            .sorted { ($0.count, $1.from, $1.to) > ($1.count, $0.from, $0.to) }
    }
    return [stage(.source, .category), stage(.category, .mode)]
}

// MARK: Insights

public struct SkillInsight: Identifiable, Sendable {
    public enum Kind: String, Sendable { case tokenHogs = "Token hogs never used", duplicates = "Duplicates across agents", stale = "Stale skills", topPerCategory = "Most used per category" }
    public let kind: Kind
    public let detail: String
    public let ids: Set<String>
    public var id: String { kind.rawValue }
}

public func skillInsights(_ facts: [SkillFacts]) -> [SkillInsight] {
    var out: [SkillInsight] = []
    let hogs = facts.filter { $0.uses == 0 && $0.tokens > 0 }.sorted { $0.tokens > $1.tokens }.prefix(10)
    if !hogs.isEmpty {
        out.append(.init(kind: .tokenHogs, detail: "\(hogs.count) cost \(formatTokens(hogs.reduce(0) { $0 + $1.tokens }))/session: " + hogs.prefix(3).map(\.skill.shortName).joined(separator: ", "), ids: Set(hogs.map(\.id))))
    }
    let dups = facts.filter { $0.skill.agents.count > 1 || !$0.skill.locations.isEmpty }
    if !dups.isEmpty { out.append(.init(kind: .duplicates, detail: "\(dups.count) skills have copies in several agents' folders", ids: Set(dups.map(\.id)))) }
    let stale = facts.filter { $0.freshness == "Stale" }
    if !stale.isEmpty { out.append(.init(kind: .stale, detail: "\(stale.count) not used in 60+ days", ids: Set(stale.map(\.id)))) }
    let tops = Dictionary(grouping: facts.filter { $0.uses > 0 }, by: \.category).compactMap { $0.value.max { $0.uses < $1.uses } }
        .sorted { $0.uses > $1.uses }
    if !tops.isEmpty { out.append(.init(kind: .topPerCategory, detail: tops.prefix(3).map { "\($0.skill.shortName) (\($0.category))" }.joined(separator: ", "), ids: Set(tops.map(\.id)))) }
    return out
}

// MARK: Clean-up findings (facts, not AI)

public struct CleanupFinding: Identifiable, Sendable {
    public enum Action: Sendable, Equatable {
        case makeCallOnly(skill: String), turnOff(skill: String), uninstall(skill: String)
        case keepOne(keep: String, remove: [String]), uninstallPlugin(String)
    }
    public enum Kind: String, Sendable, CaseIterable {
        case unusedCostly = "Unused but costly", agentDuplicate = "Copies across agents", stale = "Stale", overlap = "Overlapping"
        case shouldBeCallOnly = "Automatic, used only rarely", disabledPlugin = "Disabled plugin still installed"
    }
    public let kind: Kind
    public let title: String
    public let why: String
    public let action: Action?
    public var id: String { kind.rawValue + "|" + title }
}

/// Deterministic prune/merge/demote findings. Actions are offered only where the app can apply them (files it owns).
public func cleanupFindings(_ facts: [SkillFacts], plugins: [Plugin], now: Date = Date()) -> [CleanupFinding] {
    func ago(_ d: Date?) -> String { d.map { "last used \(Int(now.timeIntervalSince($0) / 86_400))d ago" } ?? "never used" }
    func why(_ f: SkillFacts) -> String { "\(formatTokens(f.tokens)) tokens/session · \(f.uses) uses · \(ago(f.skill.lastUsed))" }
    var out: [CleanupFinding] = []
    var seen = Set<String>()
    for f in facts where f.uses == 0 && f.tokens >= 30 && f.skill.state == .always {
        seen.insert(f.id)
        out.append(.init(kind: .unusedCostly, title: "/" + f.skill.name, why: why(f), action: f.skill.ownsFile ? .makeCallOnly(skill: f.id) : nil))
    }
    for f in facts where !seen.contains(f.id) && f.skill.state == .always && (1...2).contains(f.uses) && f.tokens >= 30 {
        seen.insert(f.id)
        out.append(.init(kind: .shouldBeCallOnly, title: "/" + f.skill.name, why: why(f), action: f.skill.ownsFile ? .makeCallOnly(skill: f.id) : nil))
    }
    for f in facts where !seen.contains(f.id) && f.freshness == "Stale" {
        out.append(.init(kind: .stale, title: "/" + f.skill.name, why: why(f), action: f.skill.ownsFile ? .uninstall(skill: f.id) : nil))
    }
    for f in facts where f.skill.locations.count > 0 {
        out.append(.init(kind: .agentDuplicate, title: "/" + f.skill.name,
                         why: "\(f.skill.locations.count + 1) copies (\(f.skill.agents.map(\.rawValue).joined(separator: ", "))) · \(f.uses) uses", action: nil))
    }
    let byID = Dictionary(facts.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    for o in skillOverlaps(facts.map(\.skill)) {
        let removable = o.skills.filter { $0.id != o.keep.id && $0.ownsFile }.map(\.id)
        out.append(.init(kind: .overlap, title: o.skills.map { "/" + $0.name }.joined(separator: " ≈ "),
                         why: o.reason + " · " + o.skills.map { "\($0.shortName) \($0.usageCount) uses, \(formatTokens(byID[$0.id]?.tokens ?? 0)) tokens" }.joined(separator: "; "),
                         action: removable.isEmpty ? nil : .keepOne(keep: o.keep.id, remove: removable)))
    }
    for p in plugins where !p.enabled {
        out.append(.init(kind: .disabledPlugin, title: p.id, why: "disabled · \(p.reach) · \(p.usageCount) uses · \(ago(p.lastUsed))", action: .uninstallPlugin(p.id)))
    }
    return out
}

// MARK: Context and file text

/// What Ask Claude gets about the map: the view, controls and every visible skill with its numbers.
public func skillMapContext(view: String, size: SkillMetric, color: SkillDimension, group: SkillDimension?, filter: SkillFilter,
                            drill: [(SkillDimension, String)], visible: [SkillFacts], total: Int) -> String {
    let chips = filter.chips.filter { !$0.value.isEmpty }.map { "\($0.key.rawValue) in [\($0.value.sorted().joined(separator: ", "))]" }.sorted()
    var l = ["## Skill map state", "view: \(view) · size by: \(size.rawValue) · color by: \(color.rawValue) · group by: \(group?.rawValue ?? "none")",
             "filters: \(chips.isEmpty ? "none" : chips.joined(separator: "; "))\(filter.search.isEmpty ? "" : " · search \"\(filter.search)\"")\(filter.ids == nil ? "" : " · insight filter (\(filter.ids!.count) skills)")",
             "drill-down: \(drill.isEmpty ? "none" : drill.map { "\($0.0.rawValue)=\($0.1)" }.joined(separator: " > "))",
             "visible: \(visible.count) of \(total) skills", "", "name | source | category | mode | uses | tokens | agents | bytes | freshness | usage band"]
    l += visible.prefix(250).map { f in
        "\(f.skill.name) | \(f.keys(.source)[0]) | \(f.category) | \(f.keys(.mode)[0]) | \(f.uses) | \(f.tokens) | \(f.skill.agents.map(\.rawValue).joined(separator: ",")) | \(f.fileBytes) | \(f.freshness) | \(UsageBand(uses: f.uses).rawValue)"
    }
    return l.joined(separator: "\n")
}

/// Frontmatter block (without fences) and the body after it.
public func splitFrontmatter(_ text: String) -> (frontmatter: String, body: String) {
    let lines = text.components(separatedBy: "\n")
    guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
          let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else { return ("", text) }
    return (lines[1..<end].joined(separator: "\n"), lines[(end + 1)...].joined(separator: "\n"))
}
