import Foundation

public struct GeminiProvider: Provider {
    public var installSpots: [URL]
    public init(installSpots: [URL] = defaultInstallSpots) { self.installSpots = installSpots }
    public let id = ProviderID.gemini
    public let displayName = "Gemini CLI"
    public let symbol = "diamond"
    public let supportedKinds: Set<ConfigKind> = [.settings, .memory, .skills, .commands, .mcp, .hooks, .permissions]

    public func detect(home: URL, env: [String: String]) -> Detection {
        Detection(executable: findExecutable("gemini", spots: installSpots, env: env), configRoot: existing(home.appending(path: ".gemini")))
    }

    public func paths(for kind: ConfigKind, home: URL, project: URL?) -> [URL] {
        let d = home.appending(path: ".gemini")
        switch kind {
        case .settings, .mcp, .hooks, .permissions: return [d.appending(path: "settings.json")]
        case .memory: return [d.appending(path: "GEMINI.md")] + (project.map { [$0.appending(path: "GEMINI.md")] } ?? [])
        case .skills: return children(d.appending(path: "extensions")).map { $0.appending(path: "skills") }.filter(exists)
        case .commands: return [d.appending(path: "commands")]  // TOML, read-only v1 (TOMLLite)
        case .agents, .plugins: return []
        }
    }

    public func ownedPaths(home: URL, projects: [URL]) -> [URL] {
        [home.appending(path: ".gemini")] + projects.map { $0.appending(path: "GEMINI.md") }
    }

    /// Headless `-p` (stdin is appended to the empty prompt), approval prompts on (so tools are denied headless), sandboxed.
    /// nil: plan mode is read-only but file tools are not confirmed cwd-confined (could read ~/.gemini/oauth_creds.json) and hooks have no off flag. Ask falls back to Claude Code.
    public func askCommand(model: String?, detection: Detection) -> AskCommand? { nil }
}
