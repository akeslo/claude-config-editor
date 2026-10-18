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

    public static func run(_ args: [String], in cwd: URL? = nil) async -> CLIResult {
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
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return CLIResult(status: p.terminationStatus, output: String(decoding: data, as: UTF8.self))
        }.value
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
