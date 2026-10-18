import Foundation
import CoreGraphics
import Testing
@testable import ConfigCore

struct SkillMapTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func skill(_ name: String, _ scope: Scope = .user, owner: String? = nil, desc: String = "x", uses: Int = 0,
               always: Bool = true, daysAgo: Double? = nil, agents: [SkillAgent] = [.claude]) -> Component {
        var c = Component(kind: .skill, name: name, scope: scope, owner: owner, file: URL(filePath: "/tmp/\(scope.rawValue)/\(owner ?? "")/\(name)/SKILL.md"),
                          description: desc, lineCount: 1, alwaysLoaded: always, frontmatterKeys: [])
        c.usageCount = uses
        c.lastUsed = daysAgo.map { now.addingTimeInterval(-$0 * 86_400) }
        c.agents = agents
        if agents.count > 1 { c.locations = [URL(filePath: "/tmp/other/\(name)/SKILL.md")] }
        return c
    }
    func facts(_ cs: [Component]) -> [SkillFacts] { skillFacts(cs, now: now, fileSize: { _ in 100 }) }

    @Test func usageBands() {
        #expect(UsageBand(uses: 0) == .never)
        #expect(UsageBand(uses: 4) == .rare)
        #expect(UsageBand(uses: 5) == .regular)
        #expect(UsageBand(uses: 30) == .heavy)
    }

    @Test func metricsAndKeys() {
        let f = facts([skill("a", uses: 3, daysAgo: 65, agents: [.claude, .codex]), skill("p:b", .plugin, owner: "pl@m", uses: 0, always: false)])
        let a = f.first { $0.skill.name == "a" }!, b = f.first { $0.skill.name == "p:b" }!
        #expect(a.value(.recency, now: now) == 300)
        #expect(a.value(.agents) == 2)
        #expect(a.value(.fileSize) == 100)
        #expect(a.freshness == "Stale")
        #expect(b.freshness == "Never used")
        #expect(b.keys(.plugin) == ["pl"])
        #expect(b.keys(.mode) == ["Call-only"])
        #expect(b.tokens == 0)
        #expect(a.keys(.agent) == ["Claude", "Codex"])
    }

    @Test func filtersAndAcrossDimensions() {
        let f = facts([skill("a", uses: 40), skill("p:b", .plugin, owner: "pl@m", uses: 40), skill("c", desc: "git stuff")])
        var flt = SkillFilter()
        flt.toggle(.usageBand, UsageBand.heavy.rawValue)
        #expect(f.filter(flt.matches).count == 2)
        flt.toggle(.source, "Plugin")
        #expect(f.filter(flt.matches).map(\.skill.name) == ["p:b"])
        flt.toggle(.source, "Plugin")   // toggles off again
        #expect(f.filter(flt.matches).count == 2)
        var s = SkillFilter(); s.search = "git"
        #expect(f.filter(s.matches).map(\.skill.name) == ["c"])
        var ids = SkillFilter(); ids.ids = [f[0].id]
        #expect(f.filter(ids.matches).count == 1)
    }

    @Test func groupingPutsMultiValuedInEachAndDashLast() {
        let f = facts([skill("a", uses: 1, agents: [.claude, .codex]), skill("b", uses: 9), skill("p:c", .plugin, owner: "x@m", uses: 2)])
        let byAgent = skillGroups(f, by: .agent)
        #expect(byAgent.map(\.key) == ["Claude", "Codex"])
        #expect(byAgent[0].items.count == 3)
        let byPlugin = skillGroups(f, by: .plugin)
        #expect(byPlugin.last?.key == "—")
        #expect(skillGroups(f, by: nil).count == 1)
    }

    @Test func squarifiedAreasAndBounds() {
        let r = CGRect(x: 0, y: 0, width: 600, height: 400)
        let vals: [Double] = [6, 6, 4, 3, 2, 2, 1, 0]
        let rects = squarify(vals, in: r)
        #expect(rects.count == vals.count)
        #expect(rects[7] == .zero)
        let total = vals.reduce(0, +)
        for (v, rc) in zip(vals, rects) where v > 0 {
            #expect(abs(Double(rc.width * rc.height) - v / total * 240_000) < 1)
            #expect(r.insetBy(dx: -0.01, dy: -0.01).contains(rc))
        }
        // No overlaps.
        for i in rects.indices { for j in rects.indices where i < j { #expect(rects[i].intersection(rects[j]).width * rects[i].intersection(rects[j]).height < 0.01) } }
        #expect(squarify([], in: r).isEmpty)
    }

    @Test func quadrants() {
        #expect(Quadrant(tokens: 100, uses: 0, tokenSplit: 50, useSplit: 1) == .expensiveUnused)
        #expect(Quadrant(tokens: 100, uses: 9, tokenSplit: 50, useSplit: 1) == .expensiveUsed)
        #expect(Quadrant(tokens: 10, uses: 9, tokenSplit: 50, useSplit: 1) == .cheapUsed)
        #expect(Quadrant(tokens: 10, uses: 0, tokenSplit: 50, useSplit: 1) == .cheapUnused)
        #expect(median([5, 1, 3]) == 3)
    }

    @Test func insights() {
        let long = String(repeating: "word ", count: 60)
        let f = facts([skill("hog", desc: long), skill("dup", uses: 2, daysAgo: 1, agents: [.claude, .codex]),
                       skill("old", uses: 3, daysAgo: 100), skill("star", desc: "git commit helper", uses: 50, daysAgo: 1)])
        let ins = Dictionary(uniqueKeysWithValues: skillInsights(f).map { ($0.kind, $0) })
        #expect(ins[.tokenHogs]?.ids.count == 1)
        #expect(ins[.duplicates]?.ids.count == 1)
        #expect(ins[.stale]?.ids.count == 1)
        #expect(ins[.topPerCategory]?.ids.contains(f.first { $0.skill.name == "star" }!.id) == true)
    }

    @Test func cleanupFindingsCoverEachKind() {
        let long = String(repeating: "word ", count: 60)
        let cs = [skill("hog", desc: long), skill("rare", desc: long + " rare", uses: 1, daysAgo: 2),
                  skill("old", uses: 3, always: false, daysAgo: 100), skill("p:hog2", .plugin, owner: "p@m", desc: long + " plug"),
                  skill("dup", uses: 2, daysAgo: 1, agents: [.claude, .codex]),
                  skill("review", uses: 1, always: false, daysAgo: 1), skill("p:review", .plugin, owner: "p@m", uses: 5, always: false, daysAgo: 1)]
        let plugins = [Plugin(id: "off@m", version: "1", scope: "user", enabled: false, installPath: URL(filePath: "/tmp/x"), notes: [])]
        let out = cleanupFindings(facts(cs), plugins: plugins, now: now)
        func find(_ k: CleanupFinding.Kind, _ t: String) -> CleanupFinding? { out.first { $0.kind == k && $0.title.contains(t) } }
        let hogID = cs[0].id
        #expect(find(.unusedCostly, "/hog")?.action == .makeCallOnly(skill: hogID))
        #expect(find(.unusedCostly, "p:hog2")?.action == nil)        // plugin skill: no file the app owns
        #expect(find(.shouldBeCallOnly, "/rare") != nil)
        #expect(find(.stale, "/old")?.action == .uninstall(skill: cs[2].id))
        #expect(find(.agentDuplicate, "/dup") != nil)
        #expect(find(.overlap, "review")?.action == .keepOne(keep: cs[6].id, remove: [cs[5].id]))
        #expect(find(.disabledPlugin, "off@m")?.action == .uninstallPlugin("off@m"))
        #expect(find(.unusedCostly, "/hog")?.why.contains("0 uses") == true)
        #expect(find(.unusedCostly, "/hog")?.why.contains("never used") == true)
    }

    @Test func flowsAndFrontmatter() {
        let f = facts([skill("a"), skill("b"), skill("p:c", .plugin, owner: "x@m", always: false)])
        let flows = skillFlows(f)
        #expect(flows.count == 2)
        #expect(flows[0].reduce(0) { $0 + $1.count } == 3)
        #expect(flows[1].contains { $0.to == "Call-only" && $0.count == 1 })
        let s = splitFrontmatter("---\nname: x\n---\n# Body")
        #expect(s.frontmatter == "name: x")
        #expect(s.body == "# Body")
        #expect(splitFrontmatter("no fm").body == "no fm")
    }

    @Test func contextNamesControlsAndRows() {
        let f = facts([skill("alpha", uses: 2)])
        var flt = SkillFilter(); flt.toggle(.source, "Personal")
        let t = skillMapContext(view: "Treemap", size: .tokens, color: .mode, group: .category, filter: flt, drill: [(.category, "Other")], visible: f, total: 9)
        #expect(t.contains("view: Treemap"))
        #expect(t.contains("Source in [Personal]"))
        #expect(t.contains("Category=Other"))
        #expect(t.contains("visible: 1 of 9"))
        #expect(t.contains("alpha | Personal"))
    }
}
