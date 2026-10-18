import Foundation
import Testing
@testable import ConfigCore

@Suite struct MemoryTests {
    func tmp() -> URL {
        let d = FileManager.default.temporaryDirectory.appending(path: "memtest-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    @Test func groupsByProjectAndAddsMissing() throws {
        let root = tmp(), proj = root.appending(path: "proj")
        try FileManager.default.createDirectory(at: proj.appending(path: ".claude/rules"), withIntermediateDirectories: true)
        let md = proj.appending(path: "CLAUDE.md"), rule = proj.appending(path: ".claude/rules/a.md"), agents = proj.appending(path: "sub/AGENTS.md")
        try "hello world".write(to: md, atomically: true, encoding: .utf8)
        try "---\npaths: x\n---\nr".write(to: rule, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: agents.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "a".write(to: agents, atomically: true, encoding: .utf8)
        let ins = [InstructionFile(kind: .claudeMD, url: md, project: proj.path, lines: 1, tokens: 3, pathScoped: false),
                   InstructionFile(kind: .rule, url: rule, project: proj.path, lines: 4, tokens: 5, pathScoped: true)]
        let groups = Memory.groups(instructions: ins, agentFiles: [agents], projects: [proj.path])
        let g = try #require(groups.first { $0.path == proj.path })
        #expect(g.entries.count == 4)  // CLAUDE.md, rule, AGENTS.md, missing CLAUDE.local.md
        #expect(g.tokens == 3)          // path-scoped rule and other-agent file don't count
        #expect(g.entries.contains { $0.type == .localMD && !$0.exists })
        #expect(g.entries.contains { $0.type == .otherAgent })
        #expect(groups.contains { $0.path == nil })
    }

    @Test func emptyGroupsHideUnlessTheyNeedCleanup() throws {
        let root = tmp(), empty = root.appending(path: "empty"), old = root.appending(path: "old")
        for d in [empty, old] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        let agents = old.appending(path: "AGENTS.md")
        try "a".write(to: agents, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -400 * 86400)], ofItemAtPath: agents.path)
        let groups = Memory.groups(instructions: [], agentFiles: [agents], projects: [empty.path, old.path])
        #expect(try #require(groups.first { $0.path == empty.path }).isEmpty)
        let stale = try #require(groups.first { $0.path == old.path })
        #expect(stale.tokens == 0 && !stale.isEmpty)  // ≈0 tokens but stale, so it stays visible
    }

    @Test func recommendations() {
        let old = Date().addingTimeInterval(-100 * 86_400)
        let long = Array(repeating: "line", count: 250).joined(separator: "\n")
        #expect(Memory.recommendations(type: .projectClaudeMD, text: long, modified: Date(), parentText: nil).contains { $0.contains("250 lines") })
        #expect(Memory.recommendations(type: .projectClaudeMD, text: "x", modified: old, parentText: nil).contains { $0.contains("Not modified") })
        let shared = "- always run the full test suite first\n- prefer small focused commits please\n- never push directly to main branch"
        #expect(Memory.recommendations(type: .projectClaudeMD, text: shared, modified: Date(), parentText: shared).contains { $0.contains("duplicate") })
        #expect(Memory.recommendations(type: .rule, text: "no frontmatter", modified: Date(), parentText: nil).contains { $0.contains("paths:") })
        #expect(Memory.recommendations(type: .projectClaudeMD, text: "fine", modified: Date(), parentText: "other").isEmpty)
    }

    @Test func resetWritesTemplateWithBackup() throws {
        let home = tmp(), f = home.appending(path: "p/CLAUDE.md")
        try FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "old".write(to: f, atomically: true, encoding: .utf8)
        let r = try #require(try Memory.reset(f, type: .projectClaudeMD, home: home))
        #expect(readText(f) == MemoryType.projectClaudeMD.template)
        #expect(readText(r.copy) == "old")
        #expect(estimateTokens("abcdefgh") == 2)
    }
}
