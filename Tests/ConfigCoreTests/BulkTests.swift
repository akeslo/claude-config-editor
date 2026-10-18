import Foundation
import Testing
@testable import ConfigCore

@Suite struct BulkTests {
    func skill(_ name: String, _ scope: Scope = .user, always: Bool = true) -> Component {
        Component(kind: .skill, name: name, scope: scope, owner: scope == .plugin ? "p@m" : nil,
                  file: URL(filePath: "/tmp/bulk/\(scope.rawValue)/\(name)/SKILL.md"), description: "d", lineCount: 1, alwaysLoaded: always, frontmatterKeys: [])
    }

    // MARK: selection with filter and range

    @Test func rangeSelectsBetweenAnchorAndClick() {
        var s = BulkSelection<String>()
        let v = ["a", "b", "c", "d", "e"]
        s.click("b", visible: v)
        s.click("d", visible: v, .range)
        #expect(s.ids == ["b", "c", "d"])
        s.click("c", visible: v, .range)   // c is on, so the range b...c... from anchor d turns off c,d
        #expect(s.ids == ["b"])
    }

    @Test func rangeFollowsVisibleOrderOnly() {
        var s = BulkSelection<String>()
        s.click("a", visible: ["a", "b", "c"])
        s.click("c", visible: ["a", "c"], .range)   // b is filtered out: not swept in
        #expect(s.ids == ["a", "c"])
    }

    @Test func selectionSurvivesFilterAndCountsHidden() {
        var s = BulkSelection<String>()
        s.selectAll(["a", "b", "c"])
        let filtered = ["a"]
        #expect(s.count == 3)
        #expect(s.hiddenCount(filtered) == 2)
        #expect(s.label(filtered) == "3 selected · 2 hidden by filter")
        #expect(s.header(filtered) == .all)
        s.toggleAll(filtered)                       // unselects only the visible row
        #expect(s.ids == ["b", "c"])
        #expect(s.header(["a", "b"]) == .some)
        s.clear()
        #expect(s.isEmpty && s.anchor == nil && s.header(filtered) == .none)
    }

    // MARK: applicability

    @Test func pluginSkillsBlockStateChanges() {
        let mixed = [skill("a"), skill("b", .plugin), skill("c", .plugin), skill("d", .plugin), skill("e")]
        let c = bulkCheck(mixed, blocked: skillBlock)
        #expect(!c.enabled)
        #expect(c.why == "3 of 5 are plugin skills (manage them in Plugins)")
        #expect(bulkCheck([skill("a"), skill("b", .project)], blocked: skillBlock) == .ok)
        #expect(!bulkCheck([Component](), blocked: skillBlock).enabled)
    }

    @Test func reasonsAreCountedSeparately() {
        let c = bulkCheck([1, 2, 3, 4], blocked: { $0 == 1 ? "are ones" : $0 > 2 ? "are big" : nil })
        #expect(c.why == "2 of 4 are big; 1 of 4 are ones")
    }

    // MARK: plan

    @Test func statePlanSkipsItemsAlreadyThere() {
        let plan = skillStatePlan([skill("a"), skill("b", always: false)], to: .onDemand)
        #expect(plan.map(\.label) == ["/a", "/b"])
        #expect(plan[0].fix != nil && plan[0].skip == nil)
        #expect(plan[1].fix == nil && plan[1].skip == "already On demand")
        #expect(Fix.bulk(plan).summary == "2 items: 1 to change, 1 skipped")
    }

    @Test func uninstallPlanTrashesTheSkillFolder() {
        guard case .trash(let urls)? = skillUninstallPlan([skill("a")])[0].fix else { Issue.record("not a trash fix"); return }
        #expect(urls.map(\.standardizedFileURL.path) == ["/tmp/bulk/User/a"])
    }

    @Test func cleanupPlanResolvesActionsAndSkipsManualFindings() {
        let a = skill("a"), b = skill("b")
        let findings = [
            CleanupFinding(kind: .unusedCostly, title: "/a", why: "", action: .makeCallOnly(skill: a.id)),
            CleanupFinding(kind: .agentDuplicate, title: "/b", why: "", action: nil),
            CleanupFinding(kind: .overlap, title: "/a ≈ /b", why: "", action: .keepOne(keep: a.id, remove: [b.id])),
            CleanupFinding(kind: .disabledPlugin, title: "p@m", why: "", action: .uninstallPlugin("p@m")),
        ]
        let plan = cleanupPlan(findings, components: [a, b])
        #expect(plan.map { $0.fix != nil } == [true, false, true, true])
        #expect(plan[1].skip == "no automatic fix")
        if case .trash(let urls)? = plan[2].fix { #expect(urls.map(\.standardizedFileURL.path) == ["/tmp/bulk/User/b"]) } else { Issue.record("overlap should trash") }
        if case .cli(let args, _, _)? = plan[3].fix { #expect(args == ["plugin", "uninstall", "p@m"]) } else { Issue.record("plugin should uninstall") }
    }

    // MARK: results

    @Test func reportCountsEveryOutcome() {
        let text = bulkReport([("/a", .done("Saved.")), ("/b", .skipped("already Off")), ("/c", .failed("disk full")), ("/d", .done(""))])
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines[0] == "2 done, 1 skipped, 1 failed")
        #expect(lines.contains("✓ /a: Saved."))
        #expect(lines.contains("– /b: skipped (already Off)"))
        #expect(lines.contains("✗ /c: failed: disk full"))
        #expect(lines.contains("✓ /d"))
    }
}
