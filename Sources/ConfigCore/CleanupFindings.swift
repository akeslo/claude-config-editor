import Foundation

/// A skill plus how fresh its use is, computed once per scan for the clean-up review.
public struct SkillFacts: Identifiable, Sendable {
    public let skill: Component
    public let freshness: String     // "Used recently" / "Stale" / "Never used"
    public var id: String { skill.id }
    public var uses: Int { skill.usageCount }
    public var tokens: Int { skill.listingTokens }
}

public func skillFacts(_ components: [Component], now: Date = Date()) -> [SkillFacts] {
    uniqueSkills(components).map { c in
        let fresh = c.usageCount == 0 ? "Never used"
            : Staleness.of(lastUsed: c.lastUsed ?? c.installedAt, now: now).level == .stale ? "Stale" : "Used recently"
        return SkillFacts(skill: c, freshness: fresh)
    }
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
