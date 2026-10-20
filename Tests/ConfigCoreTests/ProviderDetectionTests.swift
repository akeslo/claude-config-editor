import Foundation
import Testing
@testable import ConfigCore

func tempHome(_ files: [String] = []) -> URL {
    let h = FileManager.default.temporaryDirectory.appending(path: "prov-\(UUID().uuidString)", directoryHint: .isDirectory)
    for f in files {
        let u = h.appending(path: f)
        try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: u.path, contents: Data("{}".utf8))
    }
    try? FileManager.default.createDirectory(at: h, withIntermediateDirectories: true)
    return h
}

@Suite struct ProviderDetectionTests {
    @Test func claudeDetectedFromFixture() {
        let h = tempHome([".claude/settings.json"])
        let d = ProviderRegistry.detected(home: h, env: [:])
        let claude = d.first { $0.0.id.rawValue == "claude" }
        #expect(claude != nil)
        #expect(claude?.1.configRoot == h.appending(path: ".claude"))
        #expect(claude?.0.supportedKinds == [.settings, .memory, .skills, .agents, .commands, .mcp, .hooks, .permissions, .plugins])
    }

    @Test func claudePathsMatchPaths() {
        let h = URL(filePath: "/fx/home"), p = URL(filePath: "/fx/proj")
        let c = ClaudeProvider()
        #expect(c.paths(for: .settings, home: h, project: nil) == [h.appending(path: ".claude/settings.json"), h.appending(path: ".claude/settings.local.json")])
        #expect(c.paths(for: .mcp, home: h, project: nil).contains(h.appending(path: ".claude.json")))
        #expect(c.paths(for: .mcp, home: h, project: p).contains(p.appending(path: ".mcp.json")))
    }

    @Test func claudeAskCommandHasNoPrompt() {
        let exe = URL(filePath: "/x/bin/claude")
        let a = ClaudeProvider().askCommand(model: "haiku", detection: Detection(executable: exe, configRoot: nil))
        #expect(a?.args.first == "-p")
        #expect(a?.args.dropFirst().first == "--model")
        #expect(a?.env["PATH"] == "/x/bin:/usr/bin:/bin")
        #expect(ClaudeProvider().askCommand(model: nil, detection: Detection(executable: nil, configRoot: h0)) == nil)
    }
    let h0 = URL(filePath: "/fx/home/.claude")
}
