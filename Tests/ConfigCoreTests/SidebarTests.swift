import Foundation
import Testing
@testable import ConfigCore

@Test func sidebarHidesUnsupportedKinds() {
    let d = Detection(executable: nil, configRoot: URL(filePath: "/x"))
    let groups = Screen.sidebar(for: [(ClaudeProvider(), d), (CursorProvider(), d), (CodexProvider(), d)])
    #expect(groups.map(\.title) == ["Claude Code", "Cursor", "Codex", "Library"])
    // Commands merge into Agents, Plugins into Skills.
    #expect(groups[0].screens == [.settings, .memory, .skills, .agents, .mcp, .hooks, .permissions].map { .kind(.claude, $0) })
    #expect(groups[2].screens.contains(.kind(.codex, .agents)) && !groups[2].screens.contains(.kind(.codex, .commands)))
    #expect(Screen.kinds(shownOn: .agents) == [.agents, .commands])
    #expect(groups[1].screens == [.kind(.cursor, .settings), .kind(.cursor, .memory), .kind(.cursor, .mcp), .kind(.cursor, .permissions)])
}

@Test func screenParse() {
    #expect(Screen.parse("codex/settings") == .kind(.codex, .settings))
    #expect(Screen.parse("backups") == .backups)
    #expect(Screen.parse("claude/commands") == .kind(.claude, .agents))
    #expect(Screen.parse("overview") == nil)
    #expect(Screen.parse("codex") == nil)
}
