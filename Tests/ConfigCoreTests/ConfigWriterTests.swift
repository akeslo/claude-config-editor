import Foundation
import Testing
@testable import ConfigCore

struct ConfigWriterTests {
    let home: URL = {
        let d = FileManager.default.temporaryDirectory.appending(path: "cw-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: d.appending(path: ".claude"), withIntermediateDirectories: true)
        return d
    }()
    let claude = ClaudeProvider()
    var cj: URL { home.appending(path: ".claude.json") }

    func backups(_ provider: String) -> [URL] {
        let root = home.appending(path: ".claude/config-editor-backups/\(provider)")
        return (FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []).filter { !$0.hasDirectoryPath }
    }

    @Test func corruptFileIsRefused() throws {
        try Data(#"{"a":"#.utf8).write(to: cj)
        #expect(throws: WriteError.unparseable(cj)) {
            try ConfigWriter.mutateJSON(cj, provider: claude, home: home, projects: [], expectedModified: nil) { $0["x"] = 1 }
        }
        #expect(try Data(contentsOf: cj) == Data(#"{"a":"#.utf8))
        // Every Claude JSON writer goes through the same guard.
        #expect(throws: WriteError.unparseable(cj)) { try ScopeMove.setJSON(cj, ["x"], 1, home: home) }
        #expect(throws: WriteError.unparseable(cj)) { try updateSettingsKey(cj, path: ["x"], value: 1, home: home) }
        #expect(throws: WriteError.unparseable(cj)) { try removeHooks(cj, [], home: home) }
        #expect(throws: WriteError.unparseable(cj)) { try SettingsEdit.setKey(cj, path: ["x"], value: 1, home: home) }
        #expect(try Data(contentsOf: cj) == Data(#"{"a":"#.utf8))
    }

    @Test func writeOutsideOwnedPathsRefused() throws {
        let x = URL(filePath: "/tmp/x.json")
        #expect(throws: WriteError.outsideKnownPaths(x)) {
            try ConfigWriter.mutateJSON(x, provider: claude, home: home, projects: [], expectedModified: nil) { $0["x"] = 1 }
        }
        #expect(throws: WriteError.outsideKnownPaths(x)) { try ConfigWriter.writeText("{}", to: x, home: home, expectedModified: nil) }
    }

    @Test func backupBeforeWrite() throws {
        try Data(#"{"old":true}"#.utf8).write(to: cj)
        let b = try #require(try ConfigWriter.mutateJSON(cj, provider: claude, home: home, projects: [], expectedModified: modificationDate(cj)) { $0["new"] = 1 })
        #expect(b.path.contains("config-editor-backups/claude/"))
        #expect(try Data(contentsOf: b) == Data(#"{"old":true}"#.utf8))
        #expect(readJSON(cj)?["new"] as? Int == 1)
    }

    @Test func keepsKeyOrderAndMode() throws {
        let f = home.appending(path: ".claude/settings.json")
        try Data("{\n  \"zeta\": 1,\n  \"alpha\": {\n    \"y\": [1, {\"q\": 1, \"b\": 2}],\n    \"x\": \"a/b\"\n  },\n  \"mid\": null\n}\n".utf8).write(to: f)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: f.path)
        try ConfigWriter.mutateJSON(f, provider: claude, home: home, projects: [], expectedModified: nil) { $0["added"] = true }
        #expect(readText(f) == "{\n  \"zeta\": 1,\n  \"alpha\": {\n    \"y\": [\n      1,\n      {\n        \"q\": 1,\n        \"b\": 2\n      }\n    ],\n    \"x\": \"a/b\"\n  },\n  \"mid\": null,\n  \"added\": true\n}\n")
        #expect(try FileManager.default.attributesOfItem(atPath: f.path)[.posixPermissions] as? Int == 0o644)
    }

    @Test func projectOutsideHomeBacksUp() throws {
        let proj = FileManager.default.temporaryDirectory.appending(path: "cwproj-\(UUID().uuidString)")
        let f = proj.appending(path: ".claude/settings.json")
        try FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"model":"opus"}"#.utf8).write(to: f)
        let b = try #require(try ConfigWriter.mutateJSON(f, provider: claude, home: home, projects: [proj], expectedModified: nil) { $0["model"] = "sonnet" })
        #expect(b.path.contains("config-editor-backups/claude/") && b.path.hasSuffix("abs" + f.standardizedFileURL.path))
        #expect(readJSON(b)?["model"] as? String == "opus")
        #expect(Backup.original(Backup.relative(f, home: home), home: home).standardizedFileURL == f.standardizedFileURL)
    }

    @Test func removeLinesByIndexKeepsDuplicates() throws {
        let f = home.appending(path: ".claude/CLAUDE.md")
        try Data("# T\n- \n- \n- \n".utf8).write(to: f)
        let r = try Memory.removeLines(at: [2], in: f, expectedModified: modificationDate(f), home: home)
        #expect(readText(f) == "# T\n- \n- \n")
        #expect(r.map { readText($0.copy) } == "# T\n- \n- \n- \n")
        #expect(throws: WriteError.changedOnDisk(f)) { try Memory.removeLines(at: [1], in: f, expectedModified: .distantPast, home: home) }
    }

    @Test func hookRemovalMatchesMatcher() throws {
        let f = home.appending(path: ".claude/settings.json")
        try Data(#"{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"lint"}]},{"matcher":"Edit","hooks":[{"type":"command","command":"lint"}]}]}}"#.utf8).write(to: f)
        try removeHooks(f, [HookRef(file: f, event: "PreToolUse", matcher: "Bash", command: "lint")], home: home)
        let groups = (readJSON(f)?["hooks"] as? JSON)?["PreToolUse"] as? [JSON]
        #expect(groups?.map { $0["matcher"] as? String } == ["Edit"])
    }

    @Test func codexTomlWrittenWholeWithBackup() throws {
        let f = home.appending(path: ".codex/config.toml")
        try FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("model = \"o3\"\n".utf8).write(to: f)
        let b = try #require(try ConfigWriter.writeText("model = \"gpt-5\"\n", to: f, provider: CodexProvider(), home: home, projects: [], expectedModified: modificationDate(f)))
        #expect(b.path.contains("config-editor-backups/codex/"))
        #expect(readText(b) == "model = \"o3\"\n" && readText(f) == "model = \"gpt-5\"\n")
        #expect(ConfigWriter.owner(of: f, home: home)?.provider.id == .codex)
    }

    @Test func symlinkedSettingsStaysALink() throws {
        let real = home.appending(path: ".claude/dotfiles/settings.json"), link = home.appending(path: ".claude/settings.json")
        try FileManager.default.createDirectory(at: real.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"model":"opus"}"#.utf8).write(to: real)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        try SettingsEdit.setKey(link, path: ["model"], value: "sonnet", home: home)
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == real.path)
        #expect(readJSON(real)?["model"] as? String == "sonnet")
    }
}
