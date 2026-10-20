import Foundation

/// The kinds of memory/instruction file, with what each is for and a shipped default.
public enum MemoryType: String, CaseIterable, Sendable {
    case userClaudeMD = "User CLAUDE.md", projectClaudeMD = "Project CLAUDE.md", localMD = "CLAUDE.local.md"
    case rule = "Rule", memoryIndex = "Auto-memory MEMORY.md", memoryTopic = "Auto-memory note", otherAgent = "Other agent file"

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
        case .memoryIndex: "Claude's own auto-memory notes for a project. Only the first 200 lines or 25KB load at startup; detail belongs in topic files it links to."
        case .memoryTopic: "One auto-memory note (one fact per file). Not loaded at startup: Claude reads it when MEMORY.md points it there."
        case .otherAgent: "Instructions for another coding agent (Codex, Gemini, Cursor…). Claude doesn't load it unless CLAUDE.md imports it with @AGENTS.md."
        }
    }

    public var whatToPut: [String] {
        switch self {
        case .userClaudeMD: ["Communication style and preferences", "Tools and shortcuts you use everywhere", "Cross-project gotchas"]
        case .projectClaudeMD: ["Commands Claude can't guess (build, test, lint)", "Non-obvious architecture and decisions", "Gotchas; never inventories readable from code"]
        case .localMD: ["Machine-specific paths and URLs", "Personal workflow tweaks", "Nothing secret in plain text"]
        case .rule: ["One topic per file", "`paths:` frontmatter for area-specific rules", "Short, imperative instructions"]
        case .memoryIndex: ["One-line pointers to topic files", "Keep under 200 lines and 25KB (rest is cut)", "Prune outdated entries"]
        case .memoryTopic: ["One fact, decision or preference per file", "Linked from MEMORY.md, or Claude won't find it", "Nothing Claude can read from the code; no secrets"]
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
        case .memoryTopic: "---\ntype: project\n---\n\n"
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
    public var recommendations: [String]
    /// One-click fixes for some of the recommendations, each shown in the confirm sheet first.
    public var actions: [MemoryAction] = []
    /// Why an auto-memory note may be out of date (30+ days old, or names a path that is gone); nil when fresh.
    public var stale: String?
}

public struct MemoryAction: Identifiable, Sendable {
    public var id: String { title }
    public let button: String
    public let title: String
    public let fix: Fix
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
    /// File creation date; else a `created:`/`date:` frontmatter date.
    /// shortcut: no git-log fallback (APFS always records creation); add one if files arrive via checkouts that reset it.
    public static func createdDate(_ url: URL, text: String?) -> Date? {
        if let d = fileDates(url).created { return d }
        let fm = Frontmatter(text ?? "")
        guard let s = fm.values["created"] ?? fm.values["date"] else { return nil }
        return (try? Date(s, strategy: .iso8601)) ?? (try? Date(s, strategy: Date.ISO8601FormatStyle().year().month().day()))
    }

    /// Empty memory: a 0-byte or whitespace-only file, frontmatter with no body, or a folder holding no .md files.
    public static func isEmpty(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return false }
        if isDir.boolValue {
            let en = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil)
            while let f = en?.nextObject() as? URL { if f.pathExtension == "md" { return false } }
            return true
        }
        guard let text = readText(url) else { return false }
        var body = Substring(text)
        if body.hasPrefix("---"), let end = body.dropFirst(3).range(of: "\n---") {
            body = body[end.upperBound...]
        }
        return body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Groups loaded instruction files plus other agents' files by project; adds missing standard files so they can be created.
    public static func groups(instructions: [InstructionFile], agentFiles: [URL], projects: [String], now: Date = Date()) -> [MemoryGroup] {
        let userText = readText(Paths.userClaudeMD) ?? ""
        var byGroup: [String?: [MemoryEntry]] = [:]
        var seen = Set<String>()
        func owner(_ path: String) -> String? {
            projects.filter { $0 != Paths.home.path && (path == $0 || path.hasPrefix($0 + "/")) }.max { $0.count < $1.count }
        }
        func entry(_ url: URL, _ type: MemoryType, tokens: Int?, loaded: Bool, problems: [String]) -> MemoryEntry {
            let text = readText(url), dates = (created: createdDate(url, text: text), modified: fileDates(url).modified)
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
        // Auto-memory topic files live next to MEMORY.md and load only on demand.
        for (key, list) in byGroup {
            for idx in list where idx.type == .memoryIndex {
                for t in topicFiles(idx.url.deletingLastPathComponent()) where seen.insert(t.path).inserted {
                    byGroup[key, default: []].append(entry(t, .memoryTopic, tokens: 0, loaded: false, problems: []))
                }
            }
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
        for k in Array(byGroup.keys) { byGroup[k] = withChecks(byGroup[k]!, now: now) }
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
        if s.level == .stale, type != .memoryTopic { out.append("\(s.reason); check it still matches the project.") }
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

    /// Markdown notes in an auto-memory folder other than the MEMORY.md index.
    public static func topicFiles(_ dir: URL) -> [URL] {
        children(dir).filter { $0.pathExtension == "md" && $0.lastPathComponent != "MEMORY.md" }.sorted { $0.path < $1.path }
    }

    /// MEMORY.md lines that link a note, with the linked path as written.
    /// `index` counts every line (blank ones too), as `removeLines(at:)` does.
    public static func indexLinks(_ text: String) -> [(index: Int, line: String, target: String)] {
        text.split(separator: "\n", omittingEmptySubsequences: false).enumerated().compactMap { i, l in
            guard let r = l.range(of: #"\]\(([^)\s]+\.md)\)"#, options: .regularExpression) else { return nil }
            return (i, String(l), String(l[r].dropFirst(2).dropLast()))
        }
    }

    /// `@path` imports outside code fences: Claude expands them at launch, relative to the importing file.
    public static func imports(_ text: String) -> [(index: Int, line: String, path: String)] {
        var fenced = false, out: [(Int, String, String)] = []
        for (i, l) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            if l.trimmingCharacters(in: .whitespaces).hasPrefix("```") { fenced.toggle(); continue }
            guard !fenced else { continue }
            for m in l.matches(of: /(?:^|\s)@([~.\/\w][^\s`]*)/) {
                let p = String(m.output.1)
                // An import names a file: a path, or something.md. Bare @mentions (handles, @latest) are not imports.
                if p.contains("/") || p.hasSuffix(".md") { out.append((i, String(l), p)) }
            }
        }
        return out
    }

    public static func resolveImport(_ p: String, from file: URL) -> URL {
        p.hasPrefix("~") ? URL(filePath: NSString(string: p).expandingTildeInPath.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: Paths.home.path))
            : p.hasPrefix("/") ? URL(filePath: p) : file.deletingLastPathComponent().appending(path: p).standardizedFileURL
    }

    /// Trash these files and, for auto-memory notes, drop the MEMORY.md lines that link them, in one step.
    public static func removal(_ urls: [URL]) -> Fix {
        var fixes: [Fix] = [.trash(urls)]
        for (dir, us) in Dictionary(grouping: urls.filter { $0.lastPathComponent != "MEMORY.md" }, by: { $0.deletingLastPathComponent() }) {
            let index = dir.appending(path: "MEMORY.md")
            guard let text = readText(index) else { continue }
            let names = Set(us.map(\.lastPathComponent))
            let lines = IndexSet(indexLinks(text).filter { names.contains(URL(filePath: $0.target).lastPathComponent) }.map(\.index))
            if !lines.isEmpty, !urls.contains(index) { fixes.append(.removeLines(file: index, lines: lines, modified: modificationDate(index))) }
        }
        return fixes.count == 1 ? fixes[0] : .many(fixes)
    }

    /// Cross-file checks: index links, unlinked notes, 25KB index cap, broken imports, facts repeated across notes.
    static func withChecks(_ entries: [MemoryEntry], now: Date = Date()) -> [MemoryEntry] {
        var out = entries
        let texts = Dictionary(uniqueKeysWithValues: entries.filter(\.exists).map { ($0.url.path, readText($0.url) ?? "") })
        func add(_ i: Int, _ rec: String, _ action: MemoryAction? = nil) {
            out[i].recommendations.append(rec)
            if let action { out[i].actions.append(action) }
        }
        var linked = Set<String>()
        for (i, e) in out.enumerated() where e.exists {
            let text = texts[e.url.path] ?? ""
            if e.type == .memoryIndex {
                let long = text.split(separator: "\n").filter { $0.count > 150 }.count
                if long > 0 { add(i, "\(long) line\(long == 1 ? "" : "s") over 150 characters; each index entry should be one short pointer.") }
                if text.utf8.count > 25_000 { add(i, "\(formatBytes(Int64(text.utf8.count))); only the first 25KB loads. Shorten entries to one line each.") }
                let dir = e.url.deletingLastPathComponent()
                let links = indexLinks(text)
                for l in links { linked.insert(dir.appending(path: l.target).standardizedFileURL.path) }
                let broken = IndexSet(links.filter { !exists(dir.appending(path: $0.target)) }.map(\.index))
                if !broken.isEmpty {
                    add(i, "\(broken.count) index line\(broken.count == 1 ? "" : "s") point at notes that no longer exist.",
                        MemoryAction(button: "Drop broken lines…", title: "Drop \(broken.count) broken line\(broken.count == 1 ? "" : "s") from \(shortPath(e.url))",
                                     fix: .removeLines(file: e.url, lines: broken, modified: e.modified)))
                }
            }
            if [.userClaudeMD, .projectClaudeMD, .localMD, .rule].contains(e.type) {
                let broken = imports(text).filter { !exists(resolveImport($0.path, from: e.url)) }
                if !broken.isEmpty {
                    add(i, "Broken @import" + (broken.count == 1 ? "" : "s") + ": " + broken.map { "@" + $0.path }.joined(separator: ", ") + " (no such file).",
                        MemoryAction(button: "Remove broken imports…", title: "Remove \(broken.count) broken @import line\(broken.count == 1 ? "" : "s") from \(shortPath(e.url))",
                                     fix: .removeLines(file: e.url, lines: IndexSet(broken.map(\.index)), modified: e.modified)))
                }
            }
        }
        for (i, e) in out.enumerated() where e.exists && (e.type == .memoryTopic || e.type == .memoryIndex) {
            let text = texts[e.url.path] ?? ""
            if e.type == .memoryTopic, text.utf8.count > 4_000 {
                add(i, "\(formatBytes(Int64(text.utf8.count))); a note should hold one fact. Split it or trim it.")
            }
            if e.type == .memoryTopic, let s = memoryStaleness(text, from: e.url, modified: e.modified, now: now) { out[i].stale = s; add(i, s + "; check it is still true.") }
        }
        let topics = out.indices.filter { out[$0].type == .memoryTopic && out[$0].exists }
        func facts(_ t: String) -> Set<String> {
            var lines = t.split(separator: "\n", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            if lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") { lines.removeSubrange(0...end) }  // frontmatter
            return Set(lines.filter { $0.count >= 30 && !$0.hasPrefix("#") })
        }
        let factSets = Dictionary(uniqueKeysWithValues: topics.map { (out[$0].url.path, facts(texts[out[$0].url.path] ?? "")) })
        for i in topics {
            let e = out[i]
            if !linked.contains(e.url.standardizedFileURL.path), out.contains(where: { $0.type == .memoryIndex && $0.exists && $0.url.deletingLastPathComponent() == e.url.deletingLastPathComponent() }) {
                add(i, "Not linked from MEMORY.md, so Claude won't find it. Link it or delete it.",
                    MemoryAction(button: "Move to Trash…", title: "Move \(e.url.lastPathComponent) to the Trash", fix: .trash([e.url])))
            }
            let mine = factSets[e.url.path] ?? []
            let twins = topics.filter { $0 != i && !(factSets[out[$0].url.path] ?? []).isDisjoint(with: mine) }.map { out[$0].url.lastPathComponent }
            if !twins.isEmpty { add(i, "Repeats a fact also in " + twins.joined(separator: ", ") + "; keep it in one note.") }
        }
        return out
    }

    /// Auto-memory goes stale fast: flag notes untouched 30+ days, or naming a ~/ or absolute path that no longer exists.
    public static func memoryStaleness(_ text: String, from file: URL, modified: Date?, now: Date = Date()) -> String? {
        let gone = text.matches(of: /(?:^|[\s`(])((?:~|\/Users|\/opt|\/Applications)\/[^\s`)'",]+)/).map { String($0.output.1) }
            .first { !exists(resolveImport($0.trimmingCharacters(in: CharacterSet(charactersIn: ".:;")), from: file)) }
        if let gone { return "Names \(gone), which no longer exists" }
        if let m = modified, now.timeIntervalSince(m) > 30 * 86_400 { return "Not updated in \(Int(now.timeIntervalSince(m) / 86_400)) days" }
        return nil
    }

    /// Deletes the lines at these 0-based indices (duplicates elsewhere stay) after backing the file up; returns the backup.
    @discardableResult
    public static func removeLines(at indices: IndexSet, in url: URL, expectedModified: Date?, home: URL = Paths.home) throws -> Backup.Record? {
        if let e = expectedModified, modificationDate(url) != e { throw WriteError.changedOnDisk(url) }
        let text = try String(contentsOf: url, encoding: .utf8)
        let kept = text.split(separator: "\n", omittingEmptySubsequences: false).enumerated().filter { !indices.contains($0.offset) }.map(\.element)
        let now = Date()
        return try ConfigWriter.writeText(kept.joined(separator: "\n"), to: url, home: home, expectedModified: expectedModified)
            .map { Backup.Record(original: url, copy: $0, date: now, removed: false) }
    }

    /// Writes the default template, backing up any existing file first.
    @discardableResult
    public static func reset(_ url: URL, type: MemoryType, home: URL = Paths.home) throws -> Backup.Record? {
        let now = Date()
        return try ConfigWriter.writeText(type.template, to: url, home: home, expectedModified: nil)
            .map { Backup.Record(original: url, copy: $0, date: now, removed: false) }
    }
}
