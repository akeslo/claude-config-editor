import XCTest

/// Regression guard for the Memory-tab crash: two `.searchable` modifiers in one window make SwiftUI
/// install duplicate NSToolbar search items, which throws when the toolbar rebuilds on a screen switch
/// (clicking Memory). The whole app must declare `.searchable` exactly once, at the window root.
final class ToolbarSearchInvariantTests: XCTestCase {
    func testOnlyOneSearchableInTheWholeApp() throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let uiDir = root.appending(path: "Sources/ClaudeConfig")
        let files = try FileManager.default.contentsOfDirectory(at: uiDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        var total = 0
        for f in files {
            let hits = try String(contentsOf: f, encoding: .utf8)
                .components(separatedBy: "\n")
                .filter { $0.contains(".searchable(") }.count
            total += hits
        }
        XCTAssertEqual(total, 1, "Exactly one .searchable allowed app-wide; more than one crashes NSToolbar on screen switch (Memory-tab crash). Route per-screen filters through \\.screenFilter instead.")
    }
}
