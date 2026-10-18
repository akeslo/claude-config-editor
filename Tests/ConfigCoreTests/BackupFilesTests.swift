import Foundation
import Testing
@testable import ConfigCore

/// Everything runs in a temp dir; the real ~/.claude is never read or written.
struct BackupFilesTests {
    let dir: URL = {
        let d = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try! FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    func put(_ rel: String, _ text: String = "x") throws -> URL {
        let u = dir.appending(path: rel)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: u)
        return u
    }

    @Test func patterns() {
        for n in ["a.json.bak", "SKILL.md.bak-20261018", "SKILL.md.bak-20261018d", "x.bak.1", "settings.json.statusline-bak-20261018",
                  "c.json.backup", "c.json.backup.17", "CLAUDE.md.orig", "CLAUDE.md~"] { #expect(BackupFiles.isBackupName(n), "\(n)") }
        for n in ["settings.json", "backup.md", "bakery.md", ".bak", "notes.md", "orig.txt"] { #expect(!BackupFiles.isBackupName(n), "\(n)") }
    }

    @Test func originalMapping() throws {
        _ = try put(".claude/settings.json")
        let s = try put(".claude/settings.json.statusline-bak-20261018")
        #expect(BackupFiles.original(of: s)?.lastPathComponent == "settings.json")
        let k = try put("skills/x/SKILL.md.bak-20261018b")
        #expect(BackupFiles.original(of: k)?.lastPathComponent == "SKILL.md")
        let r = try put("hooks/register.tsx.bak-20261018")
        #expect(BackupFiles.original(of: r)?.lastPathComponent == "register.tsx")
        #expect(BackupFiles.original(of: dir.appending(path: "CLAUDE.md~"))?.lastPathComponent == "CLAUDE.md")
    }

    @Test func scanExcludesCacheModulesBinariesAndSymlinks() throws {
        let claude = dir.appending(path: ".claude")
        _ = try put(".claude/settings.json.bak")
        _ = try put(".claude/mods/m/hooks/register.tsx.bak-20261018")
        _ = try put(".claude/plugins/cache/p/x.json.bak")
        _ = try put(".claude/mods/m/node_modules/y.js.bak")
        try Data([0x53, 0x51, 0, 1]).write(to: claude.appending(path: "dam.db.bak"))
        let outside = try put("outside/secret.json.bak")
        try FileManager.default.createSymbolicLink(at: claude.appending(path: "link"), withDestinationURL: outside.deletingLastPathComponent())
        try FileManager.default.createSymbolicLink(at: claude.appending(path: "f.json.bak"), withDestinationURL: outside)
        _ = try put("proj/CLAUDE.md.bak")
        _ = try put("proj/src/deep.md.bak")
        let found = BackupFiles.scan(deep: [claude], shallow: [dir.appending(path: "proj")]).map(\.url.lastPathComponent).sorted()
        #expect(found == ["CLAUDE.md.bak", "register.tsx.bak-20261018", "settings.json.bak"])
    }

    @Test func restoreSnapshotsCurrentFirst() throws {
        let orig = try put("p/.claude/c.json", "new")
        let bak = try put("p/.claude/c.json.bak", "old")
        let b = try #require(BackupFiles.scan(deep: [dir.appending(path: "p/.claude")], shallow: []).first)
        #expect(BackupFiles.diff(b).contains("+old"))
        let snap = try #require(try BackupFiles.restore(b, home: dir))
        #expect(readText(orig) == "old")
        #expect(readText(snap.copy) == "new")
        #expect(exists(bak))
    }
}
