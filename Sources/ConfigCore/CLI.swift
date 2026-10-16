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
        guard let exe = executable else { return CLIResult(status: -1, output: "The claude command was not found in ~/.local/bin, /opt/homebrew/bin or /usr/local/bin.") }
        return await Task.detached {
            let p = Process()
            p.executableURL = exe
            p.arguments = args
            p.currentDirectoryURL = cwd ?? Paths.home
            var env = ProcessInfo.processInfo.environment
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

    public static func json(_ args: [String]) async -> Any? {
        let r = await run(args)
        guard r.ok, let start = r.output.firstIndex(where: { $0 == "{" || $0 == "[" }) else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(r.output[start...].utf8))
    }
}
