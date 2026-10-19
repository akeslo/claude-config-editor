import Foundation
import Testing
@testable import ConfigCore

@Suite struct MemoryEmptyTests {
    let dir = FileManager.default.temporaryDirectory.appending(path: "memempty-\(UUID().uuidString)")

    func file(_ name: String, _ text: String) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let u = dir.appending(path: name); try Data(text.utf8).write(to: u); return u
    }

    @Test func detectsEveryKindOfEmpty() throws {
        #expect(Memory.isEmpty(try file("zero.md", "")))
        #expect(Memory.isEmpty(try file("space.md", "  \n\t\n")))
        #expect(Memory.isEmpty(try file("fm.md", "---\nname: x\ntype: user\n---\n\n")))
        #expect(!Memory.isEmpty(try file("body.md", "---\nname: x\n---\nPrefers short answers.\n")))
        #expect(!Memory.isEmpty(try file("plain.md", "# Notes\n")))
        #expect(!Memory.isEmpty(dir.appending(path: "missing.md")))
    }

    @Test func folderIsEmptyOnlyWithoutMarkdown() throws {
        let folder = dir.appending(path: "memory")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        #expect(Memory.isEmpty(folder))
        try Data("x".utf8).write(to: folder.appending(path: ".DS_Store"))
        #expect(Memory.isEmpty(folder))
        try Data("x".utf8).write(to: folder.appending(path: "note.md"))
        #expect(!Memory.isEmpty(folder))
    }

    @Test func createdDateUsesFileCreation() throws {
        let u = try file("c.md", "---\ncreated: 2024-01-02\n---\nx")
        let d = try #require(Memory.createdDate(u, text: readText(u)))
        #expect(abs(d.timeIntervalSinceNow) < 120)   // APFS creation time wins over frontmatter
        #expect(Memory.createdDate(dir.appending(path: "gone.md"), text: "---\ncreated: 2024-01-02\n---\n") != nil)   // falls back to frontmatter
    }

    @Test func shiftRangeAndCommandToggleCombine() {
        var s = BulkSelection<Int>()
        let v = Array(1...8)
        s.click(2, visible: v)            // click
        s.click(5, visible: v, .range)    // ⇧-click: 2...5
        s.click(7, visible: v)            // ⌘-click adds one
        s.click(3, visible: v)            // ⌘-click removes one
        #expect(s.ids == [2, 4, 5, 7])
        s.click(8, visible: v, .range)    // ⇧ from anchor 3 to 8 sets all on
        #expect(s.ids == [2, 3, 4, 5, 6, 7, 8])
    }
}
