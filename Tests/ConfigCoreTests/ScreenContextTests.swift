import Foundation
import Testing
@testable import ConfigCore

struct ScreenContextTests {
    func comp(_ name: String, _ desc: String, scope: Scope = .user, alwaysLoaded: Bool = true) -> Component {
        Component(kind: .skill, name: name, scope: scope, owner: nil, file: URL(filePath: "/tmp/nope/\(name)/SKILL.md"),
                  description: desc, lineCount: 3, alwaysLoaded: alwaysLoaded, frontmatterKeys: ["name", "description"])
    }

    func snapshot() -> Snapshot {
        var s = Snapshot()
        s.components = [comp("deploy-helper", "Deploys things"), comp("lazy-one", String(repeating: "x", count: 900), alwaysLoaded: false)]
        s.mcpServers = [MCPServer(name: "github", scope: .user, project: nil, source: URL(filePath: "/tmp/.claude.json"),
                                  command: "npx gh-mcp --token=ghp_SUPERSECRET123", transport: "stdio",
                                  env: ["GITHUB_TOKEN": "ghp_ENVSECRET456"], headers: [:], raw: "")]
        return s
    }

    @Test func discoverSendsItemsNotJustTotals() {
        let avail = [AvailablePlugin(id: "zz@m", name: "zz-unrelated", description: "Kubernetes things", marketplace: "m", installCount: 9000, installed: false),
                     AvailablePlugin(id: "ad@m", name: "ad-writer", description: "Writes marketing ad copy " + String(repeating: "y", count: 300),
                                     marketplace: "acme-market", installCount: 42, installed: true)]
        let comm = [CommunitySkill(name: "brand-voice", description: "Marketing tone guide", category: "Marketing", stars: 7,
                                   slug: "a/b", path: nil, list: .composio)]
        let d = ScreenContext.Discover(tab: "community", search: "", available: avail, community: comm, communityInstalled: [comm[0].id])
        let t = ScreenContext.build(.discover, snapshot(), issues: [], advice: Advice(rules: []), discover: d,
                                    question: "i'm looking for skills across ad copy like marketing")
        #expect(t.contains("ad-writer | acme-market | 42 | installed | Writes marketing ad copy"))
        #expect(t.contains("brand-voice | Marketing | composio | 7 | installed | Marketing tone guide"))
        #expect(t.contains("deploy-helper") && t.contains("Deploys things"))
        #expect(t.contains("active tab: Community skills"))
        #expect(t.contains("search filter: (none)"))
        #expect(!t.contains("not itemised"))
        // Relevance beats install count; descriptions are cut to ~120 chars.
        #expect(t.range(of: "ad-writer")!.lowerBound < t.range(of: "zz-unrelated")!.lowerBound)
        #expect(!t.contains(String(repeating: "y", count: 130)))
    }

    @Test func discoverCapsLongLists() {
        let many = (0..<200).map { AvailablePlugin(id: "p\($0)", name: "p\($0)", description: "", marketplace: "m", installCount: $0, installed: false) }
        let d = ScreenContext.Discover(tab: "plugins", search: "p1", available: many, community: [], communityInstalled: [])
        let t = ScreenContext.build(.discover, Snapshot(), issues: [], advice: Advice(rules: []), discover: d)
        #expect(t.contains("+50 more not shown"))
        #expect(t.contains("search filter: \"p1\""))
    }

    @Test func inventoryIncludesItemsAndLabels() {
        let t = ScreenContext.build(.mySkills, snapshot(), issues: [], advice: Advice(rules: []))
        #expect(t.contains("deploy-helper"))
        #expect(t.contains("lazy-one | User | - | On demand"))
        #expect(t.contains("github"))
        #expect(t.contains("GITHUB_TOKEN"))
        #expect(t.contains("Your skills:"))
        #expect(t.contains("On demand:"))
    }

    @Test func secretsMasked() {
        let t = ScreenContext.build(.mcp, snapshot(), issues: [], advice: Advice(rules: []))
        #expect(!t.contains("SUPERSECRET"))
        #expect(!t.contains("ENVSECRET"))
    }

    @Test func truncationIsAnnounced() {
        let t = ScreenContext.build(.mySkills, snapshot(), issues: [], advice: Advice(rules: []))
        #expect(t.contains("…[trimmed]"))
        #expect(t.contains("1 descriptions/commands longer than"))
        let small = ScreenContext.build(.mySkills, snapshot(), issues: [], advice: Advice(rules: []), budget: 200)
        #expect(small.contains("over the 200-character budget"))
    }
}

struct FailureTests {
    let home: URL = {
        let d = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try! FileManager.default.createDirectory(at: d.appending(path: ".claude/skills"), withIntermediateDirectories: true)
        return d
    }()

    func write(_ rel: String, _ text: String) {
        let u = home.appending(path: rel)
        try! FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! Data(text.utf8).write(to: u)
    }

    @Test func detectsBrokenSkillsAndBadJSON() {
        try! FileManager.default.createDirectory(at: home.appending(path: ".claude/skills/empty"), withIntermediateDirectories: true)
        write(".claude/skills/nofm/SKILL.md", "just text")
        write(".claude/skills/nodesc/SKILL.md", "---\nname: nodesc\n---\nbody")
        write(".claude/skills/good/SKILL.md", "---\nname: good\ndescription: fine\n---\n")
        write(".claude/settings.json", "{ \"a\": ")
        let titles = Failures.detect(Snapshot(), home: home).map(\.title)
        #expect(titles.contains("Skill folder has no SKILL.md"))
        #expect(titles.contains("Skill has no frontmatter"))
        #expect(titles.contains("Skill has no description"))
        #expect(titles.contains("Config file is not valid JSON"))
        #expect(titles.count == 4)
        #expect(Failures.detect(Snapshot(), home: home).allSatisfy { $0.category == .broken })
    }

    @Test func detectsMissingPluginHookAndMCP() {
        write("hook.sh", "echo hi")  // not executable
        var s = Snapshot()
        s.plugins = [Plugin(id: "gone@m", version: "1", scope: "user", enabled: true, installPath: home.appending(path: "nope"), notes: [])]
        s.hooks = [Hook(event: "Stop", matcher: nil, matcherIsValid: true, command: home.appending(path: "hook.sh").path, timeout: nil,
                        async: false, source: "User", sourceURL: home.appending(path: ".claude/settings.json"), scriptPath: home.appending(path: "hook.sh"))]
        s.mcpServers = [MCPServer(name: "x", scope: .user, project: nil, source: home, command: "definitely-not-a-cmd-zz --a",
                                  transport: "stdio", env: [:], headers: [:], raw: "")]
        let titles = Set(Failures.detect(s, home: home).map(\.title))
        #expect(titles == ["Plugin files are missing", "Hook script is not executable", "MCP server command not found"])
    }
}
