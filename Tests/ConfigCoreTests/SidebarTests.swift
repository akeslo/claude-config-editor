import Foundation
import Testing
@testable import ConfigCore

@Test func sidebarHidesUnsupportedKinds() {
    let d = Detection(executable: nil, configRoot: URL(filePath: "/x"))
    let groups = Screen.sidebar(for: [(ClaudeProvider(), d), (CursorProvider(), d)])
    #expect(groups.map(\.title) == ["Overview", "Claude Code", "Cursor", "Library"])
    let claude = groups[1].screens
    #expect(claude.count == 9 && claude.contains(.kind(.claude, .plugins)))
    #expect(groups[2].screens == [.kind(.cursor, .settings), .kind(.cursor, .memory), .kind(.cursor, .mcp), .kind(.cursor, .permissions)])
    #expect(!groups.contains { $0.title == "Codex" })
}

@Test func screenParse() {
    #expect(Screen.parse("codex/settings") == .kind(.codex, .settings))
    #expect(Screen.parse("library/disk") == .library(.disk))
    #expect(Screen.parse("overview") == .overview)
    #expect(Screen.parse("codex") == nil)
}
