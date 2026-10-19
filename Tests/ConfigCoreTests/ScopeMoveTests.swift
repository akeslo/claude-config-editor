import Foundation
import Testing
@testable import ConfigCore

/// Every scope move runs in a temp home, then is undone, and the files must match the start.
@Suite struct ScopeMoveTests {
    let home: URL
    let proj: String

    init() throws {
        home = FileManager.default.temporaryDirectory.appending(path: "scopemove-\(UUID().uuidString)")
        proj = home.appending(path: "work/demo").path
        try FileManager.default.createDirectory(at: URL(filePath: proj).appending(path: ".claude"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.appending(path: ".claude"), withIntermediateDirectories: true)
    }

    func write(_ url: URL, _ text: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
    func json(_ url: URL) -> JSON { readJSON(url) ?? [:] }
    var userSettings: URL { home.appending(path: ".claude/settings.json") }
    var projSettings: URL { URL(filePath: proj).appending(path: ".claude/settings.json") }
    var localSettings: URL { URL(filePath: proj).appending(path: ".claude/settings.local.json") }

    @Test func skillMovesUserToProjectAndBack() async throws {
        let file = home.appending(path: ".claude/skills/tidy/SKILL.md")
        try write(file, "---\nname: tidy\n---\n")
        let c = Component(kind: .skill, name: "tidy", scope: .user, owner: nil, file: file, description: "", lineCount: 3, alwaysLoaded: true, frontmatterKeys: [])
        let undo = try ScopeMove.move(component: c, to: .project(proj), home: home)
        #expect(!exists(file))
        #expect(exists(URL(filePath: proj).appending(path: ".claude/skills/tidy/SKILL.md")))
        #expect(!Backup.list(home: home).isEmpty)   // backup kept
        try await Apply.undo(undo, home: home)
        #expect(exists(file))
        #expect(!exists(URL(filePath: proj).appending(path: ".claude/skills/tidy")))
    }

    @Test func agentAndCommandMove() throws {
        for (kind, folder) in [(ComponentKind.subagent, "agents"), (.command, "commands")] {
            let file = URL(filePath: proj).appending(path: ".claude/\(folder)/x.md")
            try write(file, "x")
            let c = Component(kind: kind, name: "x", scope: .project, owner: proj, file: file, description: "", lineCount: 1, alwaysLoaded: true, frontmatterKeys: [])
            _ = try ScopeMove.move(component: c, to: .user, home: home)
            #expect(exists(home.appending(path: ".claude/\(folder)/x.md")))
            #expect(throws: ScopeMoveError.self) { try ScopeMove.move(component: c, to: .local(proj), home: home) }
        }
    }

    @Test func moveRefusesToOverwrite() throws {
        let a = home.appending(path: ".claude/agents/r.md"), b = URL(filePath: proj).appending(path: ".claude/agents/r.md")
        try write(a, "user"); try write(b, "project")
        let c = Component(kind: .subagent, name: "r", scope: .user, owner: nil, file: a, description: "", lineCount: 1, alwaysLoaded: true, frontmatterKeys: [])
        #expect(throws: ScopeMoveError.exists(shortPath(b))) { try ScopeMove.move(component: c, to: .project(proj), home: home) }
        #expect(readText(a) == "user" && readText(b) == "project")
    }

    @Test func permissionRuleMovesToLocalAndBack() async throws {
        try write(projSettings, #"{"permissions":{"allow":["Bash(make)","Read"]},"model":"opus"}"#)
        let r = PermissionRule(kind: "allow", rule: "Bash(make)", source: "Project", sourceURL: projSettings)
        let undo = try ScopeMove.move(rule: r, to: .local(proj), home: home)
        #expect((json(localSettings)["permissions"] as? JSON)?["allow"] as? [String] == ["Bash(make)"])
        #expect((json(projSettings)["permissions"] as? JSON)?["allow"] as? [String] == ["Read"])
        #expect(json(projSettings)["model"] as? String == "opus")   // other keys kept
        try await Apply.undo(undo, home: home)
        #expect((json(projSettings)["permissions"] as? JSON)?["allow"] as? [String] == ["Bash(make)", "Read"])
        #expect((json(localSettings)["permissions"] as? JSON)?["allow"] == nil)
    }

    @Test func hookMovesWithMatcherAndBack() async throws {
        try write(userSettings, #"{"hooks":{"PostToolUse":[{"matcher":"Edit","hooks":[{"type":"command","command":"fmt","timeout":5}]}]}}"#)
        let h = Hook(event: "PostToolUse", matcher: "Edit", matcherIsValid: true, command: "fmt", timeout: 5, async: false, source: "User", sourceURL: userSettings, scriptPath: nil)
        let undo = try ScopeMove.move(hook: h, to: .project(proj), home: home)
        let moved = ((json(projSettings)["hooks"] as? JSON)?["PostToolUse"] as? [JSON])?.first
        #expect(moved?["matcher"] as? String == "Edit")
        #expect(((moved?["hooks"] as? [JSON])?.first)?["timeout"] as? Int == 5)
        #expect(json(userSettings)["hooks"] == nil)
        try await Apply.undo(undo, home: home)
        #expect(((json(userSettings)["hooks"] as? JSON)?["PostToolUse"] as? [JSON])?.count == 1)
        #expect((json(projSettings)["hooks"] as? JSON)?["PostToolUse"] == nil)
    }

    @Test func settingKeyMovesAndRefusesConflict() async throws {
        try write(userSettings, #"{"model":"opus","theme":"dark"}"#)
        let undo = try ScopeMove.move(settingKey: "model", from: userSettings, to: .project(proj), home: home)
        #expect(json(projSettings)["model"] as? String == "opus" && json(userSettings)["model"] == nil)
        try await Apply.undo(undo, home: home)
        #expect(json(userSettings)["model"] as? String == "opus")
        try write(localSettings, #"{"theme":"light"}"#)
        #expect(throws: ScopeMoveError.self) { try ScopeMove.move(settingKey: "theme", from: userSettings, to: .local(proj), home: home) }
    }

    @Test func mcpMovesBetweenAllThreeScopes() async throws {
        let cj = home.appending(path: ".claude.json")
        try write(cj, #"{"mcpServers":{"fetch":{"command":"uvx"}},"projects":{"\#(proj)":{"hasTrustDialogAccepted":true}},"numStartups":7}"#)
        func server(_ scope: Scope) -> MCPServer {
            MCPServer(name: "fetch", scope: scope, project: scope == .user ? nil : proj, source: cj, command: "uvx", transport: "stdio", env: [:], headers: [:], raw: "")
        }
        let u1 = try ScopeMove.move(mcp: server(.user), to: .local(proj), home: home)
        #expect((((json(cj)["projects"] as? JSON)?[proj] as? JSON)?["mcpServers"] as? JSON)?["fetch"] != nil)
        #expect(((json(cj)["projects"] as? JSON)?[proj] as? JSON)?["hasTrustDialogAccepted"] as? Bool == true)
        #expect(json(cj)["numStartups"] as? Int == 7)
        let u2 = try ScopeMove.move(mcp: server(.local), to: .project(proj), home: home)
        #expect((json(URL(filePath: proj).appending(path: ".mcp.json"))["mcpServers"] as? JSON)?["fetch"] != nil)
        try await Apply.undo(u2, home: home)
        try await Apply.undo(u1, home: home)
        #expect((json(cj)["mcpServers"] as? JSON)?["fetch"] != nil)
        #expect((json(URL(filePath: proj).appending(path: ".mcp.json"))["mcpServers"] as? JSON)?["fetch"] == nil)
    }

    @Test func memoryFileMovesProjectToLocal() async throws {
        let md = URL(filePath: proj).appending(path: "CLAUDE.md")
        try write(md, "# Demo")
        let f = InstructionFile(kind: .claudeMD, url: md, project: proj, lines: 1, tokens: 2, pathScoped: false)
        let undo = try ScopeMove.move(instruction: f, to: .local(proj), home: home)
        #expect(readText(URL(filePath: proj).appending(path: "CLAUDE.local.md")) == "# Demo" && !exists(md))
        try await Apply.undo(undo, home: home)
        #expect(exists(md))
    }

    @Test func pluginMoveUsesScopedCLIAndReversibleUndo() throws {
        var p = Plugin(id: "hermitd@hermitd", version: "1", scope: "local", enabled: true, installPath: URL(filePath: "/x"), notes: [])
        p.projectPath = proj
        let m = try #require(ScopeMove.pluginMove(p, to: .user))
        #expect(m.steps.map(\.args) == [["plugin", "install", "hermitd@hermitd", "--scope", "user"],
                                         ["plugin", "uninstall", "hermitd@hermitd", "--scope", "local", "--keep-data"]])
        #expect(m.steps.last?.cwd == proj)
        // Undo runs reversed: reinstall locally first, then remove the user copy.
        let order = m.undo.reversed().compactMap { if case .cli(let a, _) = $0 { a } else { nil } }
        #expect(order.first == ["plugin", "install", "hermitd@hermitd", "--scope", "local"])
        #expect(order.last == ["plugin", "uninstall", "hermitd@hermitd", "--scope", "user", "--keep-data"])
        #expect(ScopeMove.pluginMove(p, to: .local(proj)) == nil)
    }

    @Test func managedAndPluginItemsAreReadOnly() {
        #expect(ScopeMove.target(ofSettings: URL(filePath: "/Library/Application Support/ClaudeCode/managed-settings.json"), home: home) == nil)
        let c = Component(kind: .skill, name: "p:s", scope: .plugin, owner: "p@m", file: URL(filePath: "/x/SKILL.md"), description: "", lineCount: 1, alwaysLoaded: true, frontmatterKeys: [])
        #expect(ScopeMove.target(of: c) == nil)
        #expect(ScopeMove.target(ofSettings: localSettings, home: home) == .local(URL(filePath: proj).standardizedFileURL.path))
    }

    // MARK: one-click apply + undo

    @Test func applySettingsKeyThenUndo() async throws {
        try write(userSettings, #"{"model":"opus"}"#)
        let o = await Apply.run(.settingsKey(file: userSettings, path: ["model"], value: nil), home: home)
        #expect(!o.failed && json(userSettings)["model"] == nil)
        try await Apply.undo(o.undo, home: home)
        #expect(json(userSettings)["model"] as? String == "opus")
    }

    @Test func applyRemoveHooksThenUndo() async throws {
        try write(userSettings, #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"say done"}]}]}}"#)
        let o = await Apply.run(.removeHooks([HookRef(file: userSettings, event: "Stop", command: "say done")]), home: home)
        #expect(json(userSettings)["hooks"] == nil)
        try await Apply.undo(o.undo, home: home)
        #expect((json(userSettings)["hooks"] as? JSON)?["Stop"] != nil)
    }

    @Test func applyFrontmatterThenUndo() async throws {
        let file = home.appending(path: ".claude/skills/t/SKILL.md")
        try write(file, "---\nname: t\n---\nbody\n")
        let o = await Apply.run(.frontmatter(file: file, key: "disable-model-invocation", value: "true"), home: home)
        #expect(readText(file)?.contains("disable-model-invocation: true") == true)
        try await Apply.undo(o.undo, home: home)
        #expect(readText(file) == "---\nname: t\n---\nbody\n")
    }

    @Test func applyTrashThenUndo() async throws {
        let f = home.appending(path: ".claude/agents/old.md")
        try write(f, "x")
        let o = await Apply.run(.trash([f]), home: home)
        #expect(!exists(f) && o.undo.count == 1)
        try await Apply.undo(o.undo, home: home)
        #expect(readText(f) == "x")
    }

    @Test func bulkApplyCollectsEveryUndo() async throws {
        try write(userSettings, #"{"a":1,"b":2}"#)
        let o = await Apply.run(.bulk([BulkStep(label: "a", fix: .settingsKey(file: userSettings, path: ["a"], value: nil)),
                                        BulkStep(label: "b", fix: .settingsKey(file: userSettings, path: ["b"], value: nil))]), home: home)
        #expect(o.summary == "Changed 2" && json(userSettings).isEmpty)
        try await Apply.undo(o.undo, home: home)
        #expect(json(userSettings)["a"] as? Int == 1 && json(userSettings)["b"] as? Int == 2)
    }

    @Test func irreversibleActionsKeepConfirm() {
        #expect(Apply.needsConfirm(.cli(args: ["plugin", "uninstall", "x@y"], dryRun: nil, cwd: nil)))
        #expect(Apply.needsConfirm(.cli(args: ["purge", "/p", "--yes"], dryRun: nil, cwd: nil)))
        #expect(Apply.needsConfirm(.cli(args: ["plugin", "update", "x@y"], dryRun: nil, cwd: nil)))
        #expect(!Apply.needsConfirm(.cli(args: ["plugin", "disable", "x@y"], dryRun: nil, cwd: nil)))
        #expect(!Apply.needsConfirm(.cli(args: ["mcp", "remove", "x", "-s", "user"], dryRun: nil, cwd: nil)))
        #expect(!Apply.needsConfirm(.trash([URL(filePath: "/tmp/x")])))
        #expect(Apply.inverse(["plugin", "disable", "x@y", "--scope", "local"]) == ["plugin", "enable", "x@y", "--scope", "local"])
    }
}
