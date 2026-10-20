import Foundation
import Testing
@testable import ConfigCore

struct BackupTests {
    let home: URL = {
        let d = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try! FileManager.default.createDirectory(at: d.appending(path: ".claude/skills/x"), withIntermediateDirectories: true)
        return d
    }()

    @Test func trashThenRestore() throws {
        let f = home.appending(path: ".claude/skills/x/SKILL.md")
        try Data("hi".utf8).write(to: f)
        let r = try Backup.trash(f, home: home)
        #expect(!exists(f))
        #expect(r.copy.path.contains("config-editor-backups/undo/"))
        #expect(r.copy.path.hasSuffix(".claude/skills/x/SKILL.md"))
        #expect(Backup.list(home: home).map(\.original.path) == [f.path])
        #expect(Backup.list(home: home).first?.removed == true)
        try Backup.restore(r)
        #expect(readText(f) == "hi")
    }

    @Test func snapshotKeepsOriginalAndRestoreOverwrites() throws {
        let f = home.appending(path: ".claude/CLAUDE.md")
        try Data("v1".utf8).write(to: f)
        let now = Date()
        let a = try Backup.snapshot(f, home: home, now: now)
        let b = try Backup.snapshot(f, home: home, now: now)
        #expect(a.copy != b.copy)
        try Data("v2".utf8).write(to: f)
        try Backup.restore(a)
        #expect(readText(f) == "v1")
    }

    @Test func outsideHomeGoesUnderAbs() throws {
        let r = try Backup.snapshot(URL(filePath: "/etc/hosts"), home: home)
        #expect(r.copy.path.hasSuffix("/abs/etc/hosts"))
        #expect(Backup.list(home: home).contains { $0.original.path == "/etc/hosts" })
    }
}

struct StalenessTests {
    let now = Date()
    func ago(_ d: Double) -> Date { now.addingTimeInterval(-d * 86_400) }

    @Test func levels() {
        #expect(Staleness.of(modified: ago(1), now: now).level == .fresh)
        #expect(Staleness.of(modified: ago(50), now: now).level == .aging)
        #expect(Staleness.of(modified: ago(100), now: now).level == .stale)
        #expect(Staleness.of(lastUsed: ago(61), now: now).reason == "Not used in 61 days")
        #expect(Staleness.of(modified: ago(1), lastUsed: ago(40), now: now).level == .aging)
        #expect(Staleness.of(modified: ago(1), pathExists: false, now: now) == (.stale, "Path no longer exists"))
    }

    @Test func dates() throws {
        let f = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try Data().write(to: f)
        let d = fileDates(f)
        #expect(d.created != nil && d.modified != nil)
    }
}
