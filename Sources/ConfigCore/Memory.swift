import Foundation

/// The kinds of memory/instruction file, with what each is for and a shipped default.
public enum MemoryType: String, CaseIterable, Sendable {
    case userClaudeMD = "User CLAUDE.md", projectClaudeMD = "Project CLAUDE.md", localMD = "CLAUDE.local.md"
    case rule = "Rule", memoryIndex = "Auto-memory MEMORY.md", otherAgent = "Other agent file"

    public init(_ k: InstructionFile.Kind, project: String?) {
        switch k {
        case .claudeMD: self = project == nil ? .userClaudeMD : .projectClaudeMD
        case .localMD: self = .localMD
        case .rule: self = .rule
        case .memoryIndex: self = .memoryIndex
        }
    }

    /// Recommended upper bound in lines.
    public var lineLimit: Int { self == .rule ? 100 : 200 }

    public var purpose: String {
        switch self {
        case .userClaudeMD: "Your personal preferences for every project: tone, tools you use, habits Claude should follow everywhere. Loaded into every session."
        case .projectClaudeMD: "Shared team instructions for one repo, checked into git: build/test commands, architecture, conventions Claude can't infer from the code."
        case .localMD: "Your private notes for one repo (not committed): local URLs, sandbox credentials locations, personal workflow. Must be gitignored."
        case .rule: "A topic-focused instruction file in .claude/rules/. With `paths:` frontmatter it loads only when matching files are touched, keeping context lean."
        case .memoryIndex: "Claude's own auto-memory notes for a project. Only the first 200 lines load at startup; detail belongs in topic files it links to."
        case .otherAgent: "Instructions for another coding agent (Codex, Gemini, Cursor…). Claude doesn't load it unless CLAUDE.md imports it with @AGENTS.md."
        }
    }

    public var whatToPut: [String] {
        switch self {
        case .userClaudeMD: ["Communication style and preferences", "Tools and shortcuts you use everywhere", "Cross-project gotchas"]
        case .projectClaudeMD: ["Commands Claude can't guess (build, test, lint)", "Non-obvious architecture and decisions", "Gotchas; never inventories readable from code"]
        case .localMD: ["Machine-specific paths and URLs", "Personal workflow tweaks", "Nothing secret in plain text"]
        case .rule: ["One topic per file", "`paths:` frontmatter for area-specific rules", "Short, imperative instructions"]
        case .memoryIndex: ["One-line pointers to topic files", "Keep under 200 lines (rest is cut)", "Prune outdated entries"]
        case .otherAgent: ["Keep in sync with CLAUDE.md or import it", "Delete if you no longer use that agent"]
        }
    }

    public var template: String {
        switch self {
        case .userClaudeMD: "# My preferences\n\n## Style\n- Be concise.\n\n## Tools\n- \n\n## Gotchas\n- \n"
        case .projectClaudeMD: "# Project\n\nOne line on what this repo is.\n\n## Commands\n- Build: \n- Test: \n\n## Architecture\n- \n\n## Gotchas\n- \n"
        case .localMD: "# Local notes (not committed)\n\n- \n"
        case .rule: "---\npaths:\n  - \"src/**\"\n---\n\n# Rule topic\n\n- \n"
        case .memoryIndex: "# Memory\n\n- \n"
        case .otherAgent: "See CLAUDE.md for project instructions.\n"
        }
    }
}

public struct MemoryEntry: Identifiable, Sendable {
    public var id: String { url.path }
    public let url: URL
    public let type: MemoryType
    public let exists: Bool
    /// Tokens added to context (0 when missing or path-scoped/not loaded).
    public let tokens: Int
    public let lines: Int
    public let loaded: Bool
    public let created: Date?
    public let modified: Date?
    public let recommendations: [String]
}

public struct MemoryGroup: Identifiable, Sendable {
    public var id: String { path ?? "user" }
    /// nil for the global user group.
    public let path: String?
    public var title: String { path.map { ($0 as NSString).lastPathComponent } ?? "User (global)" }
    public var entries: [MemoryEntry]
    public var tokens: Int { entries.map(\.tokens).reduce(0, +) }
    /// ≈0 tokens in context and nothing to clean up (stale or problem files keep a group visible).
    public var isEmpty: Bool { tokens == 0 && !entries.contains { $0.exists && !$0.recommendations.isEmpty } }
}

public enum Memory {
    /// Groups loaded instruction files plus other agents' files by project; adds missing standard files so they can be created.
    public static func groups(instructions: [InstructionFile], agentFiles: [URL], projects: [String], now: Date = Date()) -> [MemoryGroup] {
        let userText = readText(Paths.userClaudeMD) ?? ""
        var byGroup: [String?: [MemoryEntry]] = [:]
        var seen = Set<String>()
        func owner(_ path: String) -> String? {
            projects.filter { $0 != Paths.home.path && (path == $0 || path.hasPrefix($0 + "/")) }.max { $0.count < $1.count }
        }
        func entry(_ url: URL, _ type: MemoryType, tokens: Int?, loaded: Bool, problems: [String]) -> MemoryEntry {
            let text = readText(url), dates = fileDates(url)
            var recs = problems
            if let text { recs += recommendations(type: type, text: text, modified: dates.modified, parentText: type == .userClaudeMD ? nil : userText, now: now) }
            recs = recs.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
            return MemoryEntry(url: url, type: type, exists: text != nil, tokens: loaded ? (tokens ?? estimateTokens(text ?? "")) : 0,
                               lines: text.map { $0.split(separator: "\n", omittingEmptySubsequences: false).count } ?? 0,
                               loaded: loaded, created: dates.created, modified: dates.modified, recommendations: recs)
        }
        for f in instructions where seen.insert(f.url.path).inserted {
            let key: String? = f.kind == .memoryIndex ? f.project.flatMap { projects.contains($0) ? $0 : nil } : f.project
            byGroup[key, default: []].append(entry(f.url, MemoryType(f.kind, project: f.project), tokens: f.tokens, loaded: !f.pathScoped, problems: f.problems))
        }
        for url in agentFiles where seen.insert(url.path).inserted {
            let p = url.path
            let key = p.hasPrefix(Paths.claudeDir.path + "/") ? nil : (owner(p) ?? url.deletingLastPathComponent().path)
            let base = AgentFiles.baseName(url.lastPathComponent)
            let type: MemoryType = base == "CLAUDE.local.md" ? .localMD : base == "CLAUDE.md" ? (key == nil ? .userClaudeMD : .projectClaudeMD) : .otherAgent
            byGroup[key, default: []].append(entry(url, type, tokens: nil, loaded: false, problems: []))
        }
        // Missing standard files, offered for Create.
        func missing(_ url: URL, _ type: MemoryType, _ key: String?) {
            if seen.insert(url.path).inserted { byGroup[key, default: []].append(entry(url, type, tokens: 0, loaded: false, problems: [])) }
        }
        missing(Paths.userClaudeMD, .userClaudeMD, nil)
        for p in projects where p != Paths.home.path && exists(URL(filePath: p)) {
            missing(URL(filePath: p).appending(path: "CLAUDE.md"), .projectClaudeMD, p)
            missing(URL(filePath: p).appending(path: "CLAUDE.local.md"), .localMD, p)
        }
        return byGroup.map { MemoryGroup(path: $0.key, entries: $0.value.sorted { ($0.exists ? 0 : 1, $0.url.path) < ($1.exists ? 0 : 1, $1.url.path) }) }
            .sorted { ($0.path == nil ? "" : $0.title.lowercased()) < ($1.path == nil ? "" : $1.title.lowercased()) }
    }

    /// Advice computed from the file content.
    public static func recommendations(type: MemoryType, text: String, modified: Date?, parentText: String?, now: Date = Date()) -> [String] {
        var out: [String] = []
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.count > type.lineLimit {
            out.append(type == .memoryIndex ? "\(lines.count) lines; only the first 200 load. Move detail into topic files." : "\(lines.count) lines; keep under \(type.lineLimit). Move area-specific parts into .claude/rules/ with paths:.")
        }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out.append("Empty file; fill it in or delete it.") }
        let s = Staleness.of(modified: modified, now: now)
        if s.level == .stale { out.append("\(s.reason); check it still matches the project.") }
        if let parentText, !parentText.isEmpty {
            func meaningful(_ t: String) -> Set<String> {
                Set(t.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.count >= 20 && !$0.hasPrefix("#") })
            }
            let dup = meaningful(text).intersection(meaningful(parentText)).count
            if dup >= 3 { out.append("\(dup) lines duplicate your user CLAUDE.md; they're already loaded everywhere.") }
        }
        if type == .rule, !text.hasPrefix("---") { out.append("No paths: frontmatter, so it loads in every session; scope it if it only applies to some files.") }
        if type != .userClaudeMD, text.range(of: #"(?i)(api[_-]?key|token|password|secret)\s*[:=]\s*\S{8,}"#, options: .regularExpression) != nil {
            out.append("Looks like it contains a secret; move it out of instruction files.")
        }
        return out
    }

    /// Writes the default template, backing up any existing file first.
    @discardableResult
    public static func reset(_ url: URL, type: MemoryType, home: URL = Paths.home) throws -> Backup.Record? {
        let record = exists(url) ? try Backup.snapshot(url, home: home) : nil
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(type.template.utf8).write(to: url, options: .atomic)
        return record
    }
}
