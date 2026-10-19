import Foundation
import Testing
@testable import ConfigCore

/// Uninstall used to always hit user scope; the CLI refuses project/local installs without --scope.
@Test func pluginFixesUseTheInstallScope() {
    let json: [[String: Any]] = [
        ["id": "hermitd@hermitd", "scope": "project", "projectPath": "/p/eoao-hermit", "enabled": false],
        ["id": "imessage@claude-plugins-official", "scope": "local", "projectPath": "/p/hermit", "enabled": false],
        ["id": "u@m", "scope": "user", "enabled": true],
    ]
    let ps = Scanner.plugins(from: json, usage: [:])
    func args(_ id: String) -> ([String], String?)? {
        guard case .cli(let a, _, let cwd)? = ps.first(where: { $0.id == id })?.cli("uninstall") else { return nil }
        return (a, cwd)
    }
    #expect(args("hermitd@hermitd")?.0 == ["plugin", "uninstall", "hermitd@hermitd", "--scope", "project"])
    #expect(args("hermitd@hermitd")?.1 == "/p/eoao-hermit")
    #expect(args("imessage@claude-plugins-official")?.0 == ["plugin", "uninstall", "imessage@claude-plugins-official", "--scope", "local"])
    #expect(args("u@m")?.0 == ["plugin", "uninstall", "u@m"])
    guard case .cli(let a, _, _)? = cleanupFix(.uninstallPlugin("imessage@claude-plugins-official"), components: [], plugins: ps) else { Issue.record("no fix"); return }
    #expect(a.suffix(2) == ["--scope", "local"])
}

@Test func skillGroupsByPrefixWithUnprefixedLast() {
    let mk = { (n: String) in sk(n, "/s/\(n)/SKILL.md", .user) }
    let g = skillGroups([mk("tidy"), mk("ponytail:review"), mk("caveman:patch"), mk("caveman:commit")])
    #expect(g.map { $0.name } == ["caveman", "ponytail", "No prefix"])
    #expect(g[0].skills.count == 2)
}

@Test func overlapsOnlyAcrossClaudeCodeSources() {
    let d = "Draft blog posts social media email newsletters landing pages"
    let a = sk("marketing:content-creation", "/p/a/SKILL.md", .plugin, owner: "marketing@x", d)
    let b = sk("marketing:draft-content", "/p/b/SKILL.md", .plugin, owner: "marketing@x", d)
    let gem = sk("tidy", "/h/.gemini/extensions/superpowers/skills/tidy/SKILL.md", .external)
    let mine = sk("tidy", "/h/.claude/skills/tidy/SKILL.md", .user)
    #expect(skillOverlaps([a, b, gem, mine]).isEmpty)
    #expect(gem.belongsTo == "Gemini · superpowers extension")
}

private func sk(_ name: String, _ path: String, _ scope: Scope, owner: String? = nil, _ desc: String = "") -> Component {
    Component(kind: .skill, name: name, scope: scope, owner: owner, file: URL(filePath: path), description: desc, lineCount: 1, alwaysLoaded: true, frontmatterKeys: [])
}

@Test func memoryStalenessFlagsMissingPathsAndAge() {
    let f = URL(filePath: "/tmp/x/note.md"), now = Date()
    #expect(Memory.memoryStaleness("see /Users/nobody/gone.swift", from: f, modified: now, now: now)?.contains("gone.swift") == true)
    #expect(Memory.memoryStaleness("fine", from: f, modified: now.addingTimeInterval(-31 * 86_400), now: now) == "Not updated in 31 days")
    #expect(Memory.memoryStaleness("fine", from: f, modified: now, now: now) == nil)
}

/// A local install enabled in its folder's settings.local.json is on, even though `claude plugin list` (run from home) says off.
@Test func localInstallEnabledInItsFolderIsNotDisabled() throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: "hermit-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir.appending(path: ".claude"), withIntermediateDirectories: true)
    try Data(#"{"enabledPlugins":{"hermitd@hermitd":true}}"#.utf8).write(to: dir.appending(path: ".claude/settings.local.json"))
    defer { try? FileManager.default.removeItem(at: dir) }
    let ps = Scanner.plugins(from: [
        ["id": "hermitd@hermitd", "scope": "local", "projectPath": dir.path, "enabled": false],
        ["id": "hermitd@hermitd", "scope": "project", "projectPath": "/nonexistent/eoao-hermit", "enabled": false],
    ] as [[String: Any]], usage: [:])
    let local = try #require(ps.first { $0.scope == "local" })
    #expect(local.enabled)
    #expect(local.reach == "local install in \(dir.lastPathComponent)")
    var snap = Snapshot()
    snap.plugins = [local]
    snap.duplicatePlugins = ps.filter { $0.scope == "project" }
    let issues = Checks.pluginChecks(snap)
    #expect(!issues.contains { $0.title == "Disabled plugin still installed" })
    let dup = try #require(issues.first { $0.title == "Plugin installed more than once" })
    #expect(dup.subject.contains("eoao-hermit"))
    guard case .cli(let a, _, _)? = dup.fix else { Issue.record("no fix for stale copy"); return }
    #expect(a.suffix(2) == ["--scope", "project"])
}
