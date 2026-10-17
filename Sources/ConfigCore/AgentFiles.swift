import Foundation

/// An instruction file for Claude or another coding agent, found anywhere on disk.
public struct AgentFile: Identifiable, Sendable, Hashable {
    public var id: String { url.path }
    public let url: URL
    public let agent: String
    public let size: Int64
    public let modified: Date?
    /// What follows the known name, minus any trailing date or number: "" for the live file, ".bak" for `CLAUDE.md.bak-20261016`.
    public var suffix: String { AgentFiles.suffix(url.lastPathComponent) }
}

public enum AgentFiles {
    /// File name → which agent reads it.
    public static let names: [String: String] = [
        "CLAUDE.md": "Claude", "CLAUDE.local.md": "Claude", "AGENTS.md": "Codex / shared", "AGENT.md": "Amp / shared",
        "GEMINI.md": "Gemini", ".cursorrules": "Cursor", ".windsurfrules": "Windsurf", ".clinerules": "Cline",
        "copilot-instructions.md": "Copilot", "CONVENTIONS.md": "Aider",
    ]
    static let skipped = ["/node_modules/", "/.build/", "/Library/", "/.Trash/", "/DerivedData/", "/.git/"]

    /// The known name a file is, or is a copy of (`CLAUDE.md.bak`, `AGENTS.md~`).
    public static func baseName(_ file: String) -> String? {
        if names[file] != nil { return file }
        return names.keys.filter { file.hasPrefix($0) && ".-_~ ".contains(file[file.index(file.startIndex, offsetBy: $0.count)]) }.max { $0.count < $1.count }
    }

    public static func suffix(_ file: String) -> String {
        guard let base = baseName(file) else { return "" }
        return String(file.dropFirst(base.count)).replacingOccurrences(of: "[-_. ]*[0-9][0-9-_.]*$", with: "", options: .regularExpression)
    }

    public static func isMatch(_ path: String) -> Bool {
        baseName((path as NSString).lastPathComponent) != nil && !skipped.contains { path.contains($0) }
    }

    /// Spotlight finds them across the disk fast; it skips hidden folders, so `~/.claude`, `~/.codex` and `~/.gemini` are added directly.
    public static func find(extra: [URL] = []) async -> [AgentFile] {
        await Task.detached(priority: .utility) {
            let query = names.keys.map { "kMDItemFSName == \"\($0)*\"c" }.joined(separator: " || ")
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
            let found = paths.filter(isMatch).map { path in
                let url = URL(filePath: path)
                return AgentFile(url: url, agent: names[baseName(url.lastPathComponent)!]!, size: fileSize(url), modified: modificationDate(url))
            }
            let more = extra.filter { !paths.contains($0.path) }.map { AgentFile(url: $0, agent: "Claude", size: fileSize($0), modified: modificationDate($0)) }
            return (found + more).sorted { $0.url.path < $1.url.path }
        }.value
    }
}
