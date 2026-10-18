import Foundation
import Testing
@testable import ConfigCore

struct SkillsTests {
    func skill(_ name: String, _ scope: Scope, owner: String? = nil, desc: String = "x", uses: Int = 0) -> Component {
        var c = Component(kind: .skill, name: name, scope: scope, owner: owner, file: URL(filePath: "/tmp/\(scope.rawValue)/\(owner ?? "")/\(name)/SKILL.md"),
                          description: desc, lineCount: 1, alwaysLoaded: true, frontmatterKeys: [])
        c.usageCount = uses
        return c
    }

    @Test func categorizer() {
        #expect(skillCategory(name: "commit-push-pr", description: "Commit and open a PR") == "Git & review")
        #expect(skillCategory(name: "systematic-debugging", description: "Use when encountering any bug") == "Testing & debugging")
        #expect(skillCategory(name: "pdf", description: "Read and fill PDF forms") == "Data & files")
        #expect(skillCategory(name: "zzz", description: "Nothing recognisable here") == "Other")
        // "ui" must be a whole word, not part of "build".
        #expect(skillCategory(name: "lean-build", description: "Quick build steps") != "Design & UI")
    }

    @Test func whenToUse() {
        #expect(skill("a", .user, desc: "Does X. Use when Y happens. More.").whenToUse == "Use when Y happens")
        #expect(skill("a", .user, desc: "Does X. Other.").whenToUse == "Does X")
    }

    @Test func overlapsSameNameAcrossScopes() {
        let o = skillOverlaps([skill("review", .user, uses: 1), skill("p:review", .plugin, owner: "p@m", uses: 5), skill("other", .user)])
        #expect(o.count == 1)
        #expect(o[0].kind == .sameName)
        #expect(o[0].keep.scope == .plugin)   // more used wins
    }

    @Test func overlapsSimilarDescriptions() {
        let d = "Generate polished slide decks presentations with charts speaker notes"
        let o = skillOverlaps([skill("a", .user, desc: d), skill("b", .project, owner: "/x", desc: d + " quickly"), skill("c", .user, desc: "Totally different words about gardening tomatoes weekly")])
        #expect(o.map(\.kind) == [.similar])
        #expect(Set(o[0].skills.map(\.name)) == ["a", "b"])
    }

    @Test func sameFileTwiceIsNotAnOverlap() {
        let a = skill("teach", .user)
        let b = Component(kind: .skill, name: "teach", scope: .project, owner: "/home", file: a.file, description: "x", lineCount: 1, alwaysLoaded: true, frontmatterKeys: [])
        #expect(skillOverlaps([a, b]).isEmpty)
        #expect(uniqueSkills([a, b]).map(\.scope) == [.user])
    }
}
