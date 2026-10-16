import Foundation

/// An instruction file for Claude or another coding agent, found anywhere on disk.
public struct AgentFile: Identifiable, Sendable, Hashable {
    public var id: String { url.path }
    public let url: URL
    public let agent: String
    public let size: Int64
    public let modified: Date?
}

public enum AgentFiles {
    /// File name → which agent reads it.
    public static let names: [String: String] = [
        "CLAUDE.md": "Claude", "CLAUDE.local.md": "Claude", "AGENTS.md": "Codex / shared", "AGENT.md": "Amp / shared",
        "GEMINI.md": "Gemini", ".cursorrules": "Cursor", ".windsurfrules": "Windsurf", ".clinerules": "Cline",
        "copilot-instructions.md": "Copilot", "CONVENTIONS.md": "Aider",
    ]
    static let skipped = ["/node_modules/", "/.build/", "/Library/", "/.Trash/", "/DerivedData/", "/.git/"]

    public static func isMatch(_ path: String) -> Bool {
        names[(path as NSString).lastPathComponent] != nil && !skipped.contains { path.contains($0) }
    }

    /// Spotlight finds them across the disk fast; it skips hidden folders, so `~/.claude`, `~/.codex` and `~/.gemini` are added directly.
    public static func find() async -> [AgentFile] {
        await Task.detached(priority: .utility) {
            let query = names.keys.map { "kMDItemFSName == \"\($0)\"" }.joined(separator: " || ")
            let p = Process(), pipe = Pipe()
            p.executableURL = URL(filePath: "/usr/bin/mdfind")
            p.arguments = [query]
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            var paths = Set<String>()
            if (try? p.run()) != nil {
                let out = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                paths.formUnion(String(decoding: out, as: UTF8.self).split(separator: "\n").map(String.init))
            }
            for dir in [".claude", ".codex", ".gemini", ".github"] {
                for f in children(Paths.home.appending(path: dir)) { paths.insert(f.path) }
            }
            return paths.filter(isMatch).map { path in
                let url = URL(filePath: path)
                return AgentFile(url: url, agent: names[url.lastPathComponent]!, size: fileSize(url), modified: modificationDate(url))
            }.sorted { $0.url.path < $1.url.path }
        }.value
    }
}
