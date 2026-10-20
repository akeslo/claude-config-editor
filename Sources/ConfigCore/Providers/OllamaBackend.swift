import Foundation

public struct OllamaBackend: ModelBackend {
    public var installSpots: [URL]
    public init(installSpots: [URL] = defaultInstallSpots) { self.installSpots = installSpots }
    public let id = "ollama"
    public func detect(home: URL, env: [String: String]) -> URL? { findExecutable("ollama", spots: installSpots, env: env) }
    /// `ollama run <model>` reads the prompt from stdin; it has no tools to restrict.
    public func askCommand(model: String, exe: URL) -> AskCommand { AskCommand(executable: exe, args: ["run", model], env: askEnv(exe: exe)) }
}
