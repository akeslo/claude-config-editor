import Foundation
import Testing
@testable import ConfigCore

struct AgentSkillsTests {
    func tmp() throws -> URL {
        let r = FileManager.default.temporaryDirectory.appending(path: "agentskills-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: r, withIntermediateDirectories: true)
        return r
    }
    func skill(_ dir: URL, _ desc: String = "Does a thing") throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "---\nname: \(dir.lastPathComponent)\ndescription: \(desc)\n---\nbody".write(to: dir.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
    }

    @Test func scansEveryAgentAndDedupes() throws {
        let home = try tmp()
        try skill(home.appending(path: ".claude/skills/hyperframes"))
        try skill(home.appending(path: ".agents/skills/hyperframes"))       // same name: merged
        try skill(home.appending(path: ".agents/skills/shared-only"))
        try skill(home.appending(path: ".codex/skills/codex-only"))
        try FileManager.default.createDirectory(at: home.appending(path: ".config/opencode/skills"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: home.appending(path: ".config/opencode/skills/linked"),
                                                   withDestinationURL: home.appending(path: ".agents/skills/shared-only"))  // same real path: merged
        try skill(home.appending(path: ".gemini/extensions/sp/skills/gem"))
        try FileManager.default.createDirectory(at: home.appending(path: ".codex/skills/not-a-skill"), withIntermediateDirectories: true)

        let claude = [Scanner.component(.skill, home.appending(path: ".claude/skills/hyperframes/SKILL.md"), "hyperframes", .user, nil, "")]
        let merged = Scanner.mergeAgentSkills(claude, dirs: SkillAgent.otherSkillDirs(home: home))
        let by = Dictionary(uniqueKeysWithValues: merged.map { ($0.name, $0) })
        #expect(merged.count == 4)
        #expect(by["hyperframes"]?.agents == [.claude, .agents])
        #expect(by["hyperframes"]?.locations.count == 1)
        #expect(by["shared-only"]?.agents == [.agents, .opencode])
        #expect(by["shared-only"]?.scope == .external)
        #expect(by["shared-only"]?.listingTokens == 0)
        #expect(by["codex-only"]?.agents == [.codex])
        #expect(by["gem"]?.agents == [.gemini])
    }

    @Test func promptNamesSkillsPathsAndTask() throws {
        let home = try tmp()
        try skill(home.appending(path: "a"), "First line")
        let s = Scanner.component(.skill, home.appending(path: "a/SKILL.md"), "a", .user, nil, "")
        let p = skillPrompt([s])
        #expect(p.hasPrefix("Task: {task}\n"))
        #expect(p.contains("- a: First line"))
        #expect(p.contains("SKILL.md: " + home.appending(path: "a/SKILL.md").path))
        #expect(!p.lowercased().contains("claude"))
    }
}
