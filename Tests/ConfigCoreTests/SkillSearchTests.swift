import Foundation
import Testing
@testable import ConfigCore

struct SkillSearchTests {
    @Test func parsesArgs() throws {
        let a = try SkillSearch.parse(["search", "viral", "demo", "--json", "--limit", "3"])
        #expect(a == .init(query: "viral demo", json: true, limit: 3))
        #expect(try SkillSearch.parse(["search", "x"]).limit == 10)
        #expect(throws: SkillSearch.UsageError.self) { try SkillSearch.parse(["search"]) }
        #expect(throws: SkillSearch.UsageError.self) { try SkillSearch.parse(["search", "x", "--limit", "0"]) }
        #expect(throws: SkillSearch.UsageError.self) { try SkillSearch.parse(["search", "x", "--bogus"]) }
        #expect(throws: SkillSearch.UsageError.self) { try SkillSearch.parse(["find", "x"]) }
    }

    @Test func ranksAndFormats() {
        let avail = [AvailablePlugin(id: "demoday@a", name: "demoday", description: "Product demo videos", marketplace: "a", installCount: 0, installed: false),
                     AvailablePlugin(id: "kube@a", name: "kube", description: "Kubernetes", marketplace: "a", installCount: 0, installed: false)]
        let hits = SkillSearch.rank("viral product demo", installed: [], available: avail, limit: 5)
        #expect(hits.map(\.name) == ["demoday"])
        #expect(hits[0].install == "/plugin install demoday@a")
        let text = SkillSearch.format(hits, json: false)
        #expect(text.hasPrefix("1. [plugin] demoday\n   Product demo videos\n   from: a\n   install: /plugin install demoday@a"))
        #expect(SkillSearch.format([], json: false) == "No matches.")
        #expect(SkillSearch.format(hits, json: true).contains("\"kind\" : \"plugin\""))
    }

    @Test func textOutputStripsControlChars() {
        let evil = [AvailablePlugin(id: "evil@m", name: "evil\u{1B}]0;x\u{07}", description: "a\u{1B}[2Jb\u{9B}c", marketplace: "m", installCount: 0, installed: false)]
        let text = SkillSearch.format(SkillSearch.rank("evil", installed: [], available: evil, limit: 5), json: false)
        #expect(!text.unicodeScalars.contains { $0.value == 0x1B || $0.value == 0x9B || $0.value == 0x07 })
    }
}
