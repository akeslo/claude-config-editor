import Foundation

public struct OpenCodeProvider: Provider {
    public var installSpots: [URL]
    public init(installSpots: [URL] = defaultInstallSpots) { self.installSpots = installSpots }
    public let id = ProviderID.opencode
    public let displayName = "opencode"
    public let symbol = "chevron.left.forwardslash.chevron.right"
    public let supportedKinds: Set<ConfigKind> = [.settings, .memory, .skills, .agents, .commands, .mcp, .permissions]

    public func detect(home: URL, env: [String: String]) -> Detection {
        Detection(executable: findExecutable("opencode", spots: installSpots, env: env), configRoot: existing(home.appending(path: ".config/opencode")))
    }

    public func paths(for kind: ConfigKind, home: URL, project: URL?) -> [URL] {
        let d = home.appending(path: ".config/opencode")
        switch kind {
        case .settings, .mcp, .permissions: return [d.appending(path: "opencode.json"), d.appending(path: "opencode.jsonc")]
        case .memory: return [d.appending(path: "AGENTS.md")] + (project.map { [$0.appending(path: "AGENTS.md")] } ?? [])
        case .skills: return [d.appending(path: "skills")]
        case .agents: return [d.appending(path: "agent")]
        case .commands: return [d.appending(path: "command")]
        case .hooks, .plugins: return []
        }
    }

    public func ownedPaths(home: URL, projects: [URL]) -> [URL] {
        [home.appending(path: ".config/opencode")] + projects.map { $0.appending(path: "AGENTS.md") }
    }

    /// No sandboxed ask confirmed for opencode: Ask stays hidden.
    public func askCommand(model: String?, detection: Detection) -> AskCommand? { nil }
}
