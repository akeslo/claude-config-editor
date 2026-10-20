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
        #expect(BackupFiles.original(of: s) == nil)   // labelled leftover: not assumed to be a copy of the live file
        _ = try put("skills/x/SKILL.md"); _ = try put("hooks/register.tsx")
        let k = try put("skills/x/SKILL.md.bak-20261018b")
        #expect(BackupFiles.original(of: k)?.lastPathComponent == "SKILL.md")
        let r = try put("hooks/register.tsx.bak-20261018")
        #expect(BackupFiles.original(of: r)?.lastPathComponent == "register.tsx")
        _ = try put("CLAUDE.md")
        #expect(BackupFiles.original(of: dir.appending(path: "CLAUDE.md~"))?.lastPathComponent == "CLAUDE.md")
        #expect(BackupFiles.original(of: dir.appending(path: "gone.md.bak")) == nil)
    }

    /// Dated folders under ~/.claude/backups map to the real files, never to a sibling inside the backup folder.
    @Test func datedBackupFolderRules() throws {
        let home = dir, b = ".claude/backups/20261018/"
        let cj = try put(".claude.json"), hist = try put(".claude/history.jsonl"), ip = try put(".claude/plugins/installed_plugins.json")
        let st = try put(".claude/settings.json"), skill = try put(".claude/skills/fluidplan/SKILL.md")
        let hermit = dir.appending(path: "hermit"), hs = try put("hermit/.claude/settings.local.json")
        let o = { (rel: String) throws -> URL? in BackupFiles.original(of: try put(b + rel), home: home, projects: [hermit]) }
        #expect(try o("claude.json.bak") == cj)
        #expect(try o("history.jsonl.bak") == hist)
        #expect(try o("installed_plugins.json.bak") == ip)
        #expect(try o("installed_plugins.json.pre-item2.bak") == nil)
        #expect(try o("settings.json.roar.bak") == nil)   // stale labelled leftover, not the live settings.json
        _ = st
        #expect(try o("hermit.settings.local.json.bak") == hs)
        #expect(try o("skills/fluidplan.SKILL.md.bak") == skill)
        #expect(BackupFiles.original(of: try put(".claude/backups/.claude.json.backup.1792340868531"), home: home) == cj)
    }

    @Test func uniqueSearchIgnoresManifests() throws {
        let real = try put(".claude/agents/odd.yaml")
        _ = try put(".claude/backups/x/MANIFEST.txt", "odd.yaml.bak  <-  ~/.claude/agents/odd.yaml")
        // A manifest is not read: without a unique same-name file the original stays unknown.
        #expect(BackupFiles.original(of: try put(".claude/backups/x/odd.yaml.bak"), home: dir) == nil)
        #expect(BackupFiles.original(of: dir.appending(path: ".claude/backups/x/odd.yaml.bak"), home: dir, index: ["odd.yaml": [real]]) == real)
        let u = try put(".claude/agents/solo.md")
        #expect(BackupFiles.original(of: try put(".claude/backups/y/solo.md.bak"), home: dir, index: ["solo.md": [u]]) == u)
    }

    @Test func untrustedFoldersAndEscapes() throws {
        let zshrc = try put(".zshrc"), proj = dir.appending(path: "repo")
        // A cloned repo's manifest is never read.
        _ = try put("repo/backups/MANIFEST", ".zshrc.bak -> ~/.zshrc")
        #expect(BackupFiles.original(of: try put("repo/backups/.zshrc.bak"), home: dir, projects: [proj], index: [".zshrc": [zshrc]]) == nil)
        // A symlink inside ~/.claude that escapes it.
        _ = try put(".claude/keep")
        try FileManager.default.createSymbolicLink(at: dir.appending(path: ".claude/esc.json"), withDestinationURL: zshrc)
        #expect(BackupFiles.original(of: try put(".claude/backups/w/esc.json.bak"), home: dir, index: ["esc.json": [dir.appending(path: ".claude/esc.json")]]) == nil)
    }

    @Test func projectBackupsFolderStaysInProject() throws {
        _ = try put(".claude/settings.json"); _ = try put(".claude.json")
        let proj = dir.appending(path: "repo")
        #expect(BackupFiles.original(of: try put("repo/backups/settings.json.bak"), home: dir, projects: [proj]) == nil)
        #expect(BackupFiles.original(of: try put("repo/backups/claude.json.bak"), home: dir, projects: [proj]) == nil)
        let own = try put("repo/.claude/agents/mine.md")
        #expect(BackupFiles.original(of: try put("repo/backups/mine.md.bak"), home: dir, projects: [proj], index: ["mine.md": [own]]) == own)
    }

    @Test func ambiguousIsUnknownAndRestoreRefusesWithoutCreating() throws {
        let a = try put("p1/.claude/agents/dup.md"), c = try put("p2/.claude/agents/dup.md")
        let claude = dir.appending(path: ".claude")
        _ = try put(".claude/backups/20261018/dup.md.bak", "old")
        let bf = try #require(BackupFiles.scan(deep: [claude, dir.appending(path: "p1/.claude"), dir.appending(path: "p2/.claude")], shallow: [], home: dir).first)
        #expect(bf.original == nil)
        #expect(throws: (any Error).self) { try BackupFiles.restore(bf, home: dir) }
        #expect(!exists(dir.appending(path: ".claude/backups/20261018/dup.md")))
        #expect(readText(a) == "x" && readText(c) == "x")
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
