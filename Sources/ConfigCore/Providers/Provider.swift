import Foundation

public enum ConfigKind: String, CaseIterable, Sendable { case settings, memory, skills, agents, commands, mcp, hooks, permissions, plugins }

public struct ProviderID: RawRepresentable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let claude = ProviderID(rawValue: "claude"), codex = ProviderID(rawValue: "codex"),
                      gemini = ProviderID(rawValue: "gemini"), cursor = ProviderID(rawValue: "cursor"),
                      opencode = ProviderID(rawValue: "opencode")
}

public struct Detection: Sendable {
    public let executable: URL?
    public let configRoot: URL?
    public var installed: Bool { executable != nil || configRoot != nil }
    public init(executable: URL?, configRoot: URL?) { self.executable = executable; self.configRoot = configRoot }
}

public struct AskCommand: Sendable {
    public let executable: URL
    public let args: [String]
    public let env: [String: String]
    public init(executable: URL, args: [String], env: [String: String]) { self.executable = executable; self.args = args; self.env = env }
}

public protocol Provider: Sendable {
    var id: ProviderID { get }
    var displayName: String { get }
    var symbol: String { get }
    func detect(home: URL, env: [String: String]) -> Detection
    var supportedKinds: Set<ConfigKind> { get }
    func paths(for kind: ConfigKind, home: URL, project: URL?) -> [URL]
    func ownedPaths(home: URL, projects: [URL]) -> [URL]
    func askCommand(model: String?, detection: Detection) -> AskCommand?
}

/// Real install spots, checked before PATH because PATH copies can be wrappers (cmux shims).
public let defaultInstallSpots: [URL] = {
    let real = FileManager.default.homeDirectoryForCurrentUser
    return [real.appending(path: ".local/bin"), URL(filePath: "/opt/homebrew/bin"), URL(filePath: "/usr/local/bin")]
}()

/// First executable `name` in `spots`, then on `env["PATH"]`.
func findExecutable(_ name: String, spots: [URL], env: [String: String]) -> URL? {
    let path = (env["PATH"] ?? "").split(separator: ":").map { URL(filePath: String($0)) }
    return (spots + path).map { $0.appending(path: name) }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
}

func existing(_ u: URL) -> URL? { exists(u) ? u : nil }

/// Scrubbed child env shared by every provider's ask (same rules as Claude's).
func askEnv(exe: URL) -> [String: String] { ClaudeCLI.askEnvironment(ProcessInfo.processInfo.environment, exe: exe) }
