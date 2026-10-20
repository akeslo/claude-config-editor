import Foundation

public struct CursorProvider: Provider {
    public var installSpots: [URL]
    public init(installSpots: [URL] = defaultInstallSpots) { self.installSpots = installSpots }
    public let id = ProviderID.cursor
    public let displayName = "Cursor"
    public let symbol = "cursorarrow"
    public let supportedKinds: Set<ConfigKind> = [.settings, .memory, .mcp, .permissions]

    public func detect(home: URL, env: [String: String]) -> Detection {
        Detection(executable: findExecutable("cursor-agent", spots: installSpots, env: env), configRoot: existing(home.appending(path: ".cursor")))
    }

    public func paths(for kind: ConfigKind, home: URL, project: URL?) -> [URL] {
        let d = home.appending(path: ".cursor")
        switch kind {
        case .settings, .permissions: return [d.appending(path: "cli-config.json")]
        case .memory: return project.map { [$0.appending(path: ".cursor/rules"), $0.appending(path: "AGENTS.md")] } ?? []
        case .mcp: return [d.appending(path: "mcp.json")]
        default: return []
        }
    }

    public func ownedPaths(home: URL, projects: [URL]) -> [URL] {
        [home.appending(path: ".cursor")] + projects.flatMap { [$0.appending(path: ".cursor"), $0.appending(path: "AGENTS.md")] }
    }

    /// Print mode without `--force`, so it can't apply changes.
    public func askCommand(model: String?, detection: Detection) -> AskCommand? {
        guard let exe = detection.executable else { return nil }
        let args = ["-p", "--output-format", "text"] + (model.map { ["--model", $0] } ?? [])
        return AskCommand(executable: exe, args: args, env: askEnv(exe: exe))
    }
}
