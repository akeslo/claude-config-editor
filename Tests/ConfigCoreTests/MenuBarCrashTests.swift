import Foundation
import Testing

/// Regression: MenuBarExtra(isInserted:) bound to @AppStorage crashed the app (NSStatusBarButton setImage
/// during window layout) when Agents & Commands opened. The crash has no data shape; guard the source.
@Test func menuBarInsertionIsNotBoundToAppStorage() throws {
    let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Sources/ClaudeConfig/App.swift")
    let src = try String(contentsOf: app, encoding: .utf8)
    #expect(src.contains("isInserted: menuBarShown"))
    #expect(!src.contains("@AppStorage(\"showSkillsMenuBar\")"))
}
