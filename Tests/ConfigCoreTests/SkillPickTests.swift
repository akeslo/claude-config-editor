import Foundation
import Testing
@testable import ConfigCore

struct SkillPickTests {
    let installed: [(name: String, description: String)] = [("code-review", "Review a diff for bugs"), ("enhance", "Sharpen a rough prompt")]
    let avail = [AvailablePlugin(id: "kube@a", name: "kube", description: "Kubernetes tools", marketplace: "a", installCount: 1, installed: false)]
    let comm = [CommunitySkill(name: "video-shotcraft", description: "Shots", category: "Video", slug: "o/r", path: "s", list: .anthropic)]

    @Test func picksBuildPromptAndDropUnknown() throws {
        let reply = #"Sure: {"picks":[{"name":"/Code-Review","job":"find bugs"},{"name":"ghost","job":"x"},{"name":"enhance"}],"install":[{"kind":"plugin","name":"kube"}]}"#
        let r = try #require(SkillPick.parse(reply, task: " fix my PR ", installed: installed, available: avail, community: comm))
        #expect(r.picks == [.init(name: "code-review", job: "find bugs"), .init(name: "enhance", job: "Sharpen a rough prompt")])
        #expect(r.prompt == "fix my PR\n\nUse these skills:\n- /code-review: find bugs\n- /enhance: Sharpen a rough prompt")
        #expect(r.install.isEmpty)  // installs only when nothing fits
    }

    @Test func noFitFallsBackToCatalogOnly() throws {
        let reply = #"{"picks":[],"install":[{"kind":"plugin","name":"kube","marketplace":"a"},{"kind":"community","name":"made-up"},{"kind":"community","name":"video-shotcraft"}]}"#
        let r = try #require(SkillPick.parse(reply, task: "deploy", installed: installed, available: avail, community: comm))
        #expect(r.noMatch && r.prompt == nil)
        #expect(r.install.map(\.id) == ["p:kube@a", "c:" + comm[0].id])
    }

    @Test func capsAtFiveAndRejectsGarbage() throws {
        let many = (1...7).map { ("s\($0)", "d") }
        let reply = "{\"picks\":[" + (1...7).map { "{\"name\":\"s\($0)\",\"job\":\"j\"}" }.joined(separator: ",") + "]}"
        #expect(try #require(SkillPick.parse(reply, task: "t", installed: many, available: [], community: [])).picks.count == 5)
        #expect(SkillPick.parse("No JSON here", task: "t", installed: installed, available: [], community: []) == nil)
    }

    @Test func promptCarriesOnlyNamesAndDescriptions() {
        let p = SkillPick.prompt(task: "ship it", skills: installed, plugins: avail, community: comm, tag: "data-x")
        #expect(p.contains("/code-review: Review a diff for bugs") && p.contains("kube [a]: Kubernetes tools") && p.contains("<data-x>"))
    }
}
