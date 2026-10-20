import Foundation

public struct CLIResult: Sendable {
    public let status: Int32
    public let output: String
    public var ok: Bool { status == 0 }
}

public enum ClaudeCLI {
    /// Apps launched from Finder get a minimal PATH, so look in the usual install spots.
    public static let executable: URL? = {
        let candidates = ["~/.local/bin/claude", "~/.claude/local/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
            .map { URL(filePath: NSString(string: $0).expandingTildeInPath) }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }()

    public static func run(_ args: [String], in cwd: URL? = nil, timeout: TimeInterval? = nil) async -> CLIResult {
        guard let env = childEnvironment(ProcessInfo.processInfo.environment) else {
            return CLIResult(status: -1, output: "Refused: claude CLI calls under tests must target a fixture CLAUDE_CONFIG_DIR, never the real ~/.claude.")
        }
        guard let exe = executable else { return CLIResult(status: -1, output: "The claude command was not found in ~/.local/bin, /opt/homebrew/bin or /usr/local/bin.") }
        return await Task.detached {
            let p = Process()
            p.executableURL = exe
            p.arguments = args
            p.currentDirectoryURL = cwd ?? Paths.home
            var env = env
            env["PATH"] = "\(exe.deletingLastPathComponent().path):/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
            env["NO_COLOR"] = "1"
            p.environment = env
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            p.standardInput = FileHandle.nullDevice
            do { try p.run() } catch { return CLIResult(status: -1, output: error.localizedDescription) }
            let timer = DispatchWorkItem { p.terminate() }
            if let timeout { DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer) }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            timer.cancel()
            return CLIResult(status: p.terminationStatus, output: String(decoding: data, as: UTF8.self))
        }.value
    }

    /// The one way the app asks a model: `claude -p` sandboxed to the prompt the app built.
    /// No user/project/local settings (so no CLAUDE.md, memory, env, plugins, hooks, statusline), no MCP,
    /// no skills/slash commands, no saved session, an app-only system prompt, a fresh empty cwd and a scrubbed env.
    /// shortcut: the CLI still attaches its built-in env block (OS, temp cwd) and the signed-in account email;
    /// only `--bare` drops those and it refuses keychain/OAuth sign-in, so switch once an API key is used.
    /// `files` are copied into the ask's temp cwd (credential files refused); no config dir is ever granted.
    public static func ask(_ prompt: String, model: String, tools: [String] = [], files: [URL] = [], timeout: TimeInterval? = nil) async -> String? {
        guard let exe = executable else { return nil }
        let cmd = AskCommand(executable: exe, args: stdinAskArgs(model: model, tools: tools), env: askEnvironment(ProcessInfo.processInfo.environment, exe: exe))
        guard case .success(let text) = await ModelSandbox.run(cmd, prompt: prompt, files: files, timeout: timeout ?? 120), !text.isEmpty else { return nil }
        return text
    }

    /// `askArgs` with the prompt slot removed: `claude -p` then reads the prompt from stdin.
    static func stdinAskArgs(model: String, tools: [String]) -> [String] {
        var a = askArgs("", model: model, tools: tools, addDir: nil)
        a.remove(at: 1)
        return a
    }

    static let askSystemPrompt = "You are the assistant inside the Claude Config app. Work only from the input in the user message (and files you are allowed to read); you have no other context about the user or their machine. This is one answer with no follow-up: never offer to search, run commands or do anything later; if the data doesn't cover something, say so."

    static func askArgs(_ prompt: String, model: String, tools: [String], addDir: URL?) -> [String] {
        var a = ["-p", prompt, "--model", model,
                 "--system-prompt", askSystemPrompt,
                 "--setting-sources", "",
                 "--settings", #"{"disableAllHooks":true}"#,
                 "--strict-mcp-config", "--mcp-config", #"{"mcpServers":{}}"#,
                 "--disable-slash-commands", "--no-session-persistence",
                 "--tools", tools.joined(separator: ",")]
        if !tools.isEmpty { a += ["--allowedTools"] + tools }
        if let addDir { a += ["--add-dir", addDir.path] }
        return a
    }

    /// Only what the CLI needs to find its keychain sign-in (HOME/USER) and run; nothing else from the app's env.
    static func askEnvironment(_ base: [String: String], exe: URL) -> [String: String] {
        var env = ["PATH": "\(exe.deletingLastPathComponent().path):/usr/bin:/bin", "NO_COLOR": "1",
                   "HOME": base["CLAUDE_CONFIG_EDITOR_CLI_HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path]
        for k in ["USER", "LOGNAME", "TMPDIR", "LANG"] { env[k] = base[k] }
        return env
    }

    /// A fixture home must also redirect the CLI's own writes (plugin registry, project installs):
    /// with cwd = fixture home, the real CLI read fixture/.claude/settings.json as *project* settings
    /// and recorded every enabled plugin in the real ~/.claude/plugins/installed_plugins.json.
    /// Returns nil (refuse) under tests when the child would still write to the real ~/.claude.
    static func childEnvironment(_ base: [String: String], realClaudeDir: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude")) -> [String: String]? {
        var env = base
        let norm = { (u: URL) in u.standardizedFileURL.resolvingSymlinksInPath().path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
        let real = norm(realClaudeDir)
        if norm(Paths.claudeDir) != real { env["CLAUDE_CONFIG_DIR"] = Paths.claudeDir.path }
        if isUnderTests, norm(env["CLAUDE_CONFIG_DIR"].map { URL(filePath: $0) } ?? realClaudeDir) == real { return nil }
        return env
    }

    static let isUnderTests = Bundle.allBundles.contains { $0.bundlePath.hasSuffix(".xctest") }
        || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        || NSClassFromString("XCTestCase") != nil || ProcessInfo.processInfo.processName == "xctest"
        || ProcessInfo.processInfo.arguments.contains { $0.hasSuffix(".xctest") || $0.contains("swift-testing") }

    public static func json(_ args: [String]) async -> Any? {
        let r = await run(args)
        guard r.ok, let start = r.output.firstIndex(where: { $0 == "{" || $0 == "[" }) else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(r.output[start...].utf8))
    }
}
