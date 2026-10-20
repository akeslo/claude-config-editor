import Foundation
import Testing
@testable import ConfigCore

@Suite struct SkillsScreenTests {
    func skill(_ i: Int, _ scope: Scope = .user) -> Component {
        Component(kind: .skill, name: "skill-number-\(i)", scope: scope, owner: scope == .plugin ? "p@m" : nil,
                  file: URL(filePath: "/tmp/ss/\(i)/SKILL.md"), description: String(repeating: "Does a useful thing for the user. ", count: 20),
                  lineCount: 1, alwaysLoaded: true, frontmatterKeys: [])
    }

    @Test func selectionDropsRowsTheFilterHides() {
        var s = BulkSelection<String>()
        s.selectAll(["a", "b", "c"]); s.anchor = "c"
        s.keepVisible(["a"])
        #expect(s.ids == ["a"] && s.anchor == nil && s.hiddenCount(["a"]) == 0)
    }

    @Test func mixedSelectionRunsOnOwnedAndSkipsPluginSkills() {
        let picked = [skill(1), skill(2, .plugin)]
        #expect(skillBulkCheck(picked) == .ok)
        #expect(!skillBulkCheck([skill(2, .plugin)]).enabled)
        let plan = skillStatePlan(picked, to: .off)
        #expect(plan[0].fix != nil && plan[1].skip == "plugin or other-agent skill")
    }

    @Test func fourHundredSkillsFitTheAskBudget() {
        var snap = Snapshot(); snap.components = (0..<400).map { skill($0) }
        let text = ScreenContext.build(.skills, snap, issues: [], advice: Advice(rules: []))
        #expect(!text.contains("were omitted"))
        #expect(text.contains("skill-number-399"))
        #expect(text.contains("complete list"))
    }

    @Test func answerMarkdownIsRendered() {
        let r = String(AnswerBlocks.rich("**Bold** text\n- item\n## Head").characters)
        #expect(r == "Bold text\n• item\nHead")
    }
}
