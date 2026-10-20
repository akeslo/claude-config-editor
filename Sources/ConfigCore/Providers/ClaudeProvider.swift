import Foundation

public struct ClaudeProvider: Provider {
    public var installSpots: [URL]
    public init(installSpots: [URL] = [FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/local")] + defaultInstallSpots) { self.installSpots = installSpots }
    public let id = ProviderID.claude
    public let displayName = "Claude Code"
    public let symbol = "sparkle"
    public let supportedKinds: Set<ConfigKind> = Set(ConfigKind.allCases)

    /// `Paths` constant moved from `Paths.home` onto `home`, so paths live in one place.
    func rebase(_ u: URL, _ home: URL) -> URL {
        u.pathComponents.dropFirst(Paths.home.pathComponents.count).reduce(home) { $0.appending(path: $1) }
    }

    public func detect(home: URL, env: [String: String]) -> Detection {
        Detection(executable: findExecutable("claude", spots: installSpots, env: env), configRoot: existing(rebase(Paths.claudeDir, home)))
    }

    public func paths(for kind: ConfigKind, home: URL, project: URL?) -> [URL] {
        let dir = rebase(Paths.claudeDir, home), settings = [rebase(Paths.userSettings, home), rebase(Paths.userLocalSettings, home)]
        let pdir = project?.appending(path: ".claude")
        switch kind {
        case .settings, .hooks, .permissions:
            return settings + (pdir.map { [$0.appending(path: "settings.json"), $0.appending(path: "settings.local.json")] } ?? [])
        case .memory:
            return [rebase(Paths.userClaudeMD, home)] + (project.map { [$0.appending(path: "CLAUDE.md"), $0.appending(path: "CLAUDE.local.md")] } ?? [])
        case .skills, .agents, .commands:
            return [dir.appending(path: kind.rawValue)] + (pdir.map { [$0.appending(path: kind.rawValue)] } ?? [])
        case .mcp: return [rebase(Paths.claudeJSON, home)] + (project.map { [$0.appending(path: ".mcp.json")] } ?? [])
        case .plugins: return [dir.appending(path: "plugins")]
        }
    }

    public func ownedPaths(home: URL, projects: [URL]) -> [URL] {
        [rebase(Paths.claudeDir, home), rebase(Paths.claudeJSON, home)]
            + projects.flatMap { [$0.appending(path: ".claude"), $0.appending(path: ".mcp.json"), $0.appending(path: "CLAUDE.md"), $0.appending(path: "CLAUDE.local.md")] }
    }

    /// Today's sandboxed `claude -p` argv minus the prompt (it goes on stdin, Task 4).
    public func askCommand(model: String?, detection: Detection) -> AskCommand? {
        guard let exe = detection.executable else { return nil }
        return AskCommand(executable: exe, args: ClaudeCLI.stdinAskArgs(model: model ?? "sonnet", tools: []), env: askEnv(exe: exe))
    }
}
