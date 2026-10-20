import Foundation
import Testing
@testable import ConfigCore

@Suite struct ProviderPathTests {
    let h = URL(filePath: "/fx/home"), p = URL(filePath: "/fx/proj")
    func u(_ s: String) -> URL { h.appending(path: s) }

    @Test func codexPathMapping() {
        let c = CodexProvider()
        #expect(c.paths(for: .settings, home: h, project: nil) == [u(".codex/config.toml")])
        #expect(c.paths(for: .memory, home: h, project: p) == [u(".codex/AGENTS.md"), p.appending(path: "AGENTS.md")])
        #expect(c.paths(for: .skills, home: h, project: nil) == [u(".codex/skills")])
        #expect(c.paths(for: .commands, home: h, project: nil) == [u(".codex/prompts")])
        #expect(c.paths(for: .mcp, home: h, project: nil) == [u(".codex/config.toml")])
        #expect(c.paths(for: .hooks, home: h, project: nil) == [u(".codex/hooks.json")])
        #expect(c.paths(for: .permissions, home: h, project: nil) == [u(".codex/rules")])
    }
    @Test func codexKindsHideUnsupported() {
        #expect(CodexProvider().supportedKinds == [.settings, .memory, .skills, .commands, .mcp, .hooks, .permissions])
        #expect(CodexProvider().paths(for: .agents, home: h, project: p).isEmpty)
    }

    @Test func geminiPathMapping() {
        let g = GeminiProvider(), fx = fixture("gemini")
        #expect(g.paths(for: .settings, home: h, project: nil) == [u(".gemini/settings.json")])
        #expect(g.paths(for: .memory, home: h, project: p) == [u(".gemini/GEMINI.md"), p.appending(path: "GEMINI.md")])
        #expect(g.paths(for: .skills, home: fx, project: nil).map(\.lastPathComponent) == ["skills"])
        #expect(g.paths(for: .skills, home: fx, project: nil).first?.deletingLastPathComponent().lastPathComponent == "superpowers")
        #expect(g.paths(for: .commands, home: h, project: nil) == [u(".gemini/commands")])
        for k in [ConfigKind.mcp, .hooks, .permissions] { #expect(g.paths(for: k, home: h, project: nil) == [u(".gemini/settings.json")]) }
    }
    @Test func geminiKindsHideUnsupported() {
        #expect(GeminiProvider().supportedKinds == [.settings, .memory, .skills, .commands, .mcp, .hooks, .permissions])
    }

    @Test func cursorPathMapping() {
        let c = CursorProvider()
        #expect(c.paths(for: .settings, home: h, project: nil) == [u(".cursor/cli-config.json")])
        #expect(c.paths(for: .memory, home: h, project: p) == [p.appending(path: ".cursor/rules"), p.appending(path: "AGENTS.md")])
        #expect(c.paths(for: .memory, home: h, project: nil).isEmpty)
        #expect(c.paths(for: .mcp, home: h, project: nil) == [u(".cursor/mcp.json")])
        #expect(c.paths(for: .permissions, home: h, project: nil) == [u(".cursor/cli-config.json")])
    }
    @Test func cursorKindsHideUnsupported() {
        let k = CursorProvider().supportedKinds
        #expect(k == [.settings, .memory, .mcp, .permissions])
        #expect(!k.contains(.skills) && !k.contains(.hooks))
    }

    @Test func opencodePathMapping() {
        let o = OpenCodeProvider(), d = ".config/opencode/"
        #expect(o.paths(for: .settings, home: h, project: nil) == [u(d + "opencode.json"), u(d + "opencode.jsonc")])
        #expect(o.paths(for: .memory, home: h, project: p) == [u(d + "AGENTS.md"), p.appending(path: "AGENTS.md")])
        #expect(o.paths(for: .skills, home: h, project: nil) == [u(d + "skills")])
        #expect(o.paths(for: .agents, home: h, project: nil) == [u(d + "agent")])
        #expect(o.paths(for: .commands, home: h, project: nil) == [u(d + "command")])
        for k in [ConfigKind.mcp, .permissions] { #expect(o.paths(for: k, home: h, project: nil) == [u(d + "opencode.json"), u(d + "opencode.jsonc")]) }
    }
    @Test func opencodeKindsHideUnsupported() {
        #expect(OpenCodeProvider().supportedKinds == [.settings, .memory, .skills, .agents, .commands, .mcp, .permissions])
    }

    @Test func ownedPathsCoverEveryPath() {
        for prov in ProviderRegistry.all {
            let owned = prov.ownedPaths(home: h, projects: [p]).map(\.path)
            for k in prov.supportedKinds { for x in prov.paths(for: k, home: h, project: p) {
                #expect(owned.contains { x.path == $0 || x.path.hasPrefix($0 + "/") }, "\(prov.id.rawValue) \(x.path)")
            } }
        }
    }

    @Test func tomlLiteReadsTablesAndMultiline() {
        let t = TOMLLite.parse(readText(fixture("codex").appending(path: ".codex/config.toml"))!)
        #expect(t[""]?["model"] == "o3")
        #expect(t["mcp_servers.docs"]?["command"] == "npx")
        #expect(t["mcp_servers.docs"]?["args"] == #"["-y", "docs"]"#)
        let g = TOMLLite.parse(readText(fixture("gemini").appending(path: ".gemini/commands/review.toml"))!)
        #expect(g[""]?["description"] == "Review code")
        #expect(g[""]?["prompt"] == "Review {{args}}\nline two\n")
    }
}

func fixture(_ id: String) -> URL {
    URL(filePath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/providers/\(id)")
}
