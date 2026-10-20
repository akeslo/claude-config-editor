import Foundation
import Testing
@testable import ConfigCore

@Suite struct ModelSandboxTests {
    func script(_ body: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "sandbox-bin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let u = dir.appending(path: "fake")
        try "#!/bin/sh\n\(body)\n".write(to: u, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: u.path)
        return u
    }
    func cmd(_ exe: URL) -> AskCommand { AskCommand(executable: exe, args: [], env: askEnv(exe: exe)) }

    @Test func promptGoesOnStdin() async throws {
        let r = await ModelSandbox.run(cmd(try script("cat")), prompt: "hello there")
        #expect(try r.get() == "hello there")
    }

    @Test func timeoutKillsProcess() async throws {
        let start = Date()
        let r = await ModelSandbox.run(cmd(try script("exec sleep 30")), prompt: "", timeout: 1)
        guard case .failure(let f) = r else { Issue.record("expected failure"); return }
        #expect(f.reason.contains("timed out"))
        #expect(Date().timeIntervalSince(start) < 10)
    }

    @Test func stderrSurfaced() async throws {
        let r = await ModelSandbox.run(cmd(try script("echo 'not logged in' >&2; exit 1")), prompt: "")
        guard case .failure(let f) = r else { Issue.record("expected failure"); return }
        #expect(f.reason.contains("not logged in"))
    }

    @Test func envScrubbed() async throws {
        let out = try await ModelSandbox.run(cmd(try script("/usr/bin/env")), prompt: "").get()
        let keys = Set(out.split(separator: "\n").compactMap { $0.split(separator: "=").first.map(String.init) })
        let shellAdded: Set<String> = ["PWD", "SHLVL", "_", "OLDPWD", "__CF_USER_TEXT_ENCODING"]
        #expect(keys.subtracting(shellAdded).isSubset(of: ["PATH", "NO_COLOR", "HOME", "USER", "LOGNAME", "TMPDIR", "LANG"]))
    }

    @Test func cwdIsEmptyTemp() async throws {
        let out = try await ModelSandbox.run(cmd(try script("pwd -P; ls -A | wc -l")), prompt: "").get()
        let lines = out.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        #expect(lines.first?.contains("claude-config-ask-") == true)
        #expect(lines.last == "0")
    }

    @Test func filesCopiedNotDirGranted() async throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "sandbox-home-\(UUID().uuidString)/.claude")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let settings = home.appending(path: "settings.json")
        try "{\"x\":1}".write(to: settings, atomically: true, encoding: .utf8)
        let c = cmd(try script("echo \"$@\"; cat settings.json"))
        let out = try await ModelSandbox.run(c, prompt: "", files: [settings]).get()
        #expect(out.contains("{\"x\":1}"))
        #expect(!out.contains(home.path))
        #expect(!ClaudeCLI.stdinAskArgs(model: "sonnet", tools: ["Read"]).contains("--add-dir"))
    }

    @Test func credentialFilesRefused() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "sandbox-cred-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let names = [".credentials.json", "auth.json", "oauth_creds.json", ".claude.json", "github_token", "my-credentials.txt", "id.key", "ok.md"]
        for n in names { try "SECRET".write(to: dir.appending(path: n), atomically: true, encoding: .utf8) }
        let sneaky = dir.appending(path: "notes.md")  // innocent name, credential target
        try FileManager.default.createSymbolicLink(at: sneaky, withDestinationURL: dir.appending(path: "auth.json"))
        let out = try await ModelSandbox.run(cmd(try script("ls -A")), prompt: "", files: names.map { dir.appending(path: $0) } + [sneaky, dir]).get()
        #expect(out == "ok.md")
    }

    @Test func askArgsPerProvider() {
        let x = URL(filePath: "/b/x"), d = Detection(executable: x, configRoot: nil)
        var claude = ClaudeCLI.askArgs("", model: "sonnet", tools: [], addDir: nil); claude.remove(at: 1)
        #expect(ClaudeProvider().askCommand(model: nil, detection: d)!.args == claude)
        #expect(CodexProvider().askCommand(model: nil, detection: d)!.args.joined(separator: " ").contains("--sandbox read-only"))
        let g = GeminiProvider().askCommand(model: nil, detection: d)!.args
        #expect(g.contains("--sandbox") && g.joined(separator: " ").contains("--approval-mode plan"))
        #expect(OllamaBackend().askCommand(model: "llama3", exe: x).args == ["run", "llama3"])
    }

    @Test func askFallsBackToClaude() throws {
        let claudeExe = try script("true"), bin = claudeExe.deletingLastPathComponent()
        try FileManager.default.moveItem(at: claudeExe, to: bin.appending(path: "claude"))
        let ps: [any Provider] = [ClaudeProvider(installSpots: [bin]), CodexProvider(installSpots: [])]
        let home = FileManager.default.temporaryDirectory
        #expect(ProviderRegistry.askCommand(for: .codex, home: home, env: ["PATH": ""], providers: ps)?.executable.lastPathComponent == "claude")
    }
}
