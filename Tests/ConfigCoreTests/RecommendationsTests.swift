import Foundation
import Testing
@testable import ConfigCore

struct RecommendationsTests {
    let avail = [AvailablePlugin(id: "demoday@a", name: "demoday", description: "Demo decks", marketplace: "a", installCount: 1, installed: false),
                 AvailablePlugin(id: "demoday@b", name: "demoday", description: "Other", marketplace: "b", installCount: 1, installed: false),
                 AvailablePlugin(id: "kube@a", name: "kube", description: "Kubernetes video tools", marketplace: "a", installCount: 1, installed: false)]
    let comm = [CommunitySkill(name: "video-shotcraft", description: "Shots", category: "Video", slug: "o/r", path: "s", list: .anthropic)]

    @Test func parsesAndStripsBlock() {
        let text = "Try these.\n```json\n[{\"kind\":\"plugin\",\"name\":\"demoday\",\"marketplace\":\"b\",\"reason\":\"decks\"}]\n```\n"
        let r = Recommendations.parse(text)
        #expect(r.prose == "Try these.")
        #expect(r.picks == [.init(kind: "plugin", name: "demoday", marketplace: "b", reason: "decks")])
    }

    @Test func missingOrMalformedBlockKeepsText() {
        #expect(Recommendations.parse("Just prose.").picks.isEmpty)
        #expect(Recommendations.parse("Just prose.").prose == "Just prose.")
        let bad = "Hi\n```json\n[{\"kind\": oops]\n```"
        #expect(Recommendations.parse(bad).picks.isEmpty)
        #expect(Recommendations.parse(bad).prose == bad)
    }

    @Test func dropsHallucinatedNamesAndPrefersMarketplace() {
        let picks: [Recommendations.Pick] = [.init(kind: "plugin", name: "demoday", marketplace: "b", reason: "x"),
                                             .init(kind: "plugin", name: "viralhunt", marketplace: nil, reason: nil),
                                             .init(kind: "community", name: "Video-Shotcraft", marketplace: nil, reason: nil),
                                             .init(kind: "community", name: "made-up", marketplace: nil, reason: nil),
                                             .init(kind: "plugin", name: "demoday", marketplace: "b", reason: "dup")]
        let ids = Recommendations.match(picks, available: avail, community: comm).map(\.id)
        #expect(ids == ["p:demoday@b", "c:o/r/s"])
    }

    @Test func quickSearchRanksNameHitsFirst() {
        #expect(Recommendations.search("video", available: avail, community: comm).map(\.id) == ["c:o/r/s", "p:kube@a"])
        #expect(Recommendations.search("  ", available: avail, community: comm).isEmpty)
    }
}
