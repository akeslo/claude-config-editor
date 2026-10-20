import Foundation

public struct CodexProvider: Provider {
    public var installSpots: [URL]
    public init(installSpots: [URL] = defaultInstallSpots) { self.installSpots = installSpots }
    public let id = ProviderID.codex
    public let displayName = "Codex"
    public let symbol = "terminal"
    public let supportedKinds: Set<ConfigKind> = [.settings, .memory, .skills, .commands, .mcp, .hooks, .permissions]

    public func detect(home: URL, env: [String: String]) -> Detection {
        Detection(executable: findExecutable("codex", spots: installSpots, env: env), configRoot: existing(home.appending(path: ".codex")))
    }

    public func paths(for kind: ConfigKind, home: URL, project: URL?) -> [URL] {
        let d = home.appending(path: ".codex")
        switch kind {
        case .settings, .mcp: return [d.appending(path: "config.toml")]
        case .memory: return [d.appending(path: "AGENTS.md")] + (project.map { [$0.appending(path: "AGENTS.md")] } ?? [])
        case .skills: return [d.appending(path: "skills")]
        case .commands: return [d.appending(path: "prompts")]
        case .hooks: return [d.appending(path: "hooks.json")]
        case .permissions: return [d.appending(path: "rules")]  // *.rules, read-only v1
        case .agents, .plugins: return []
        }
    }

    public func ownedPaths(home: URL, projects: [URL]) -> [URL] {
        [home.appending(path: ".codex")] + projects.map { $0.appending(path: "AGENTS.md") }
    }

    /// Read-only sandbox, no git check, no saved session; `-` reads the prompt from stdin.
    public func askCommand(model: String?, detection: Detection) -> AskCommand? {
        guard let exe = detection.executable else { return nil }
        let args = ["exec", "--sandbox", "read-only", "--skip-git-repo-check", "--ephemeral"] + (model.map { ["-m", $0] } ?? []) + ["-"]
        return AskCommand(executable: exe, args: args, env: askEnv(exe: exe))
    }
}
