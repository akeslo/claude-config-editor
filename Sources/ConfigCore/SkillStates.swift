import Foundation

/// The three plain states a skill can be in, from the owner's point of view.
public enum SkillState: String, CaseIterable, Sendable {
    case always = "Always available", onDemand = "On demand", off = "Off"

    public var explanation: String {
        switch self {
        case .always: "Listed every session, so Claude can pick it by itself. Costs its description in tokens."
        case .onDemand: "Not listed. You call it with /name. Costs nothing until you do."
        case .off: "Not listed and can't be called."
        }
    }
}

extension Component {
    public var state: SkillState {
        if override == "off" { return .off }
        return !alwaysLoaded || override == "user-invocable-only" ? .onDemand : .always
    }

    /// What it costs per session in a given state: the listing entry when always available, nothing otherwise.
    public func tokens(in state: SkillState) -> Int {
        state == .always ? (override == "name-only" ? estimateTokens(name) + 4 : estimateTokens(name + description) + 4) : 0
    }

    /// Personal and project skills. skillOverrides doesn't apply to plugin skills, and plugin updates replace their files,
    /// so a plugin skill follows its plugin being on or off.
    public var ownsFile: Bool { scope == .user || scope == .project }

    /// The change that puts this skill in `target`, or nil when it is already there.
    public func fix(to target: SkillState) -> Fix? {
        guard target != state, ownsFile else { return nil }
        var steps: [Fix] = []
        let settingsOverride = { (v: String?) in Fix.settingsKey(file: Paths.userSettings, path: ["skillOverrides", name], value: v) }
        switch target {
        case .always:
            if override != nil { steps.append(settingsOverride(nil)) }
            if !alwaysLoaded { steps.append(.frontmatter(file: file, key: "disable-model-invocation", value: nil)) }
        case .onDemand:
            if override != nil { steps.append(settingsOverride(nil)) }
            steps.append(.frontmatter(file: file, key: "disable-model-invocation", value: "true"))
        case .off:
            steps.append(settingsOverride("off"))
        }
        return steps.count == 1 ? steps[0] : .many(steps)
    }
}

/// What triage suggests for one skill, with a one-line reason that names its source.
public struct SkillSuggestion: Sendable, Equatable {
    public enum Action: Sendable, Equatable {
        case state(SkillState)
        case moveToProject(String)   // advice only: the app never moves skill folders
        case removeDuplicate         // advice only: skillOverrides is keyed by name, so Off would hit the personal copy too
    }
    public let action: Action
    public let reason: String
    public var state: SkillState? { if case .state(let s) = action { s } else { nil } }
    public var label: String {
        switch action {
        case .state(let s): s.rawValue
        case .moveToProject(let p): "Move to " + (p as NSString).lastPathComponent
        case .removeDuplicate: "Remove duplicate"
        }
    }
}

/// Triage rules for personal and project skills, first match wins. Never suggests Off for a skill that is merely unused;
/// Off is only for a copy that can't run anyway.
/// - `projects`: known project folders, for "only relevant to one project".
/// - `budget`: listing budget in tokens (about 1% of a 200k context).
public func skillSuggestions(_ components: [Component], projects: [String] = [], budget: Int = 2_000, now: Date = Date()) -> [String: SkillSuggestion] {
    let skills = components.filter { $0.kind == .skill }
    var out: [String: SkillSuggestion] = [:]
    let candidates = skills.filter { $0.ownsFile && $0.state == .always }
    let days = { (c: Component) in c.lastUsed.map { now.timeIntervalSince($0) / 86_400 } }

    // 1. Shadowed duplicates: personal beats project, so a same-named project skill never runs.
    for c in skills where c.scope == .project && skills.contains(where: { $0.scope == .user && $0.name == c.name }) {
        out[c.id] = SkillSuggestion(action: .removeDuplicate, reason: "A personal /\(c.name) overrides this copy, so it never runs (Claude Code docs: skill precedence)")
    }
    for c in candidates where out[c.id] == nil {
        // 2. Personal skill that names exactly one project: belongs in that project's .claude/skills.
        if c.scope == .user {
            let text = (c.name + " " + c.description).lowercased()
            let hits = projects.filter { p in
                let n = (p as NSString).lastPathComponent.lowercased()
                return n.count >= 4 && !n.hasPrefix(".") && text.contains(n)  // skip hidden folders like ~/.claude
            }
            if hits.count == 1 {
                out[c.id] = SkillSuggestion(action: .moveToProject(hits[0]), reason: "Mentions only \((hits[0] as NSString).lastPathComponent); its .claude/skills keeps it out of other projects (Claude Code docs)")
                continue
            }
        }
        // 3. Never used.
        if c.usageCount == 0 {
            out[c.id] = SkillSuggestion(action: .state(.onDemand), reason: "Never used, costs \(formatTokens(c.listingTokens)) every session (/skill-doctor: never invoked)")
        // 4. Stale: not used in 60 days.
        } else if let d = days(c), d > 60 {
            out[c.id] = SkillSuggestion(action: .state(.onDemand), reason: "Last used \(Int(d)) days ago; keep a small always-on core (community practice)")
        }
    }
    // 5. Overlap: two always-on skills whose descriptions share most words compete for the same requests; keep the more used one listed.
    let open = candidates.filter { out[$0.id] == nil }
    for (i, a) in open.enumerated() {
        for b in open[(i + 1)...] where out[a.id] == nil && out[b.id] == nil && descriptionOverlap(a.description, b.description) >= 0.5 {
            let (keep, drop) = (a.usageCount, a.lastUsed ?? .distantPast) >= (b.usageCount, b.lastUsed ?? .distantPast) ? (a, b) : (b, a)
            out[drop.id] = SkillSuggestion(action: .state(.onDemand), reason: "Overlaps /\(keep.name), which you use more; overlapping skills crowd each other out (community practice)")
        }
    }
    // 6. Over the listing budget: descriptions get cut, so move the least-used remaining skills to On demand until it fits,
    // sparing anything used in the last two weeks.
    var total = skills.filter { out[$0.id]?.state == nil }.reduce(0) { $0 + $1.listingTokens }
    for c in open.filter({ out[$0.id] == nil && (days($0) ?? .infinity) > 14 }).sorted(by: { ($0.usageCount, $0.lastUsed ?? .distantPast) < ($1.usageCount, $1.lastUsed ?? .distantPast) }) where total > budget {
        out[c.id] = SkillSuggestion(action: .state(.onDemand), reason: "Skill listing is over its ~1% context budget and this is among your least used (Claude Code docs: skill listing budget)")
        total -= c.listingTokens
    }
    return out
}

/// Share of meaningful words two descriptions have in common (Jaccard), 0...1.
func descriptionOverlap(_ a: String, _ b: String) -> Double {
    let words = { (s: String) in Set(s.lowercased().split { !$0.isLetter }.map(String.init).filter { $0.count > 3 && !stopWords.contains($0) }) }
    let (x, y) = (words(a), words(b))
    guard x.count >= 4, y.count >= 4 else { return 0 }
    return Double(x.intersection(y).count) / Double(x.union(y).count)
}

private let stopWords: Set<String> = ["this", "that", "with", "when", "from", "your", "user", "skill", "skills", "claude", "code", "should", "these", "them", "then", "into", "also", "using", "used", "asks", "want", "wants", "like", "only", "will", "have", "about", "trigger", "triggers"]

/// Sets (or with nil, removes) one top-level key in a Markdown file's YAML frontmatter, keeping everything else byte for byte.
public func setFrontmatterKey(_ url: URL, key: String, value: String?, backupDir: URL = Paths.appBackups) throws -> URL? {
    let loadedAt = modificationDate(url)
    let text = readText(url) ?? ""
    let updated = frontmatterSetting(text, key: key, value: value)
    guard updated != text else { return nil }
    return try safeWrite(Data(updated.utf8), to: url, expectedModified: loadedAt, backupDir: backupDir)
}

func frontmatterSetting(_ text: String, key: String, value: String?) -> String {
    let eol = text.contains("\r\n") ? "\r" : ""  // keep a CRLF file CRLF
    var lines = text.components(separatedBy: "\n")
    // Any top-level spelling of the key ('key :', "key":, 'key':) counts, so a duplicate can't shadow the value we write.
    let isKey = { (l: String) -> Bool in
        guard let c = l.firstIndex(of: ":"), !(l.first?.isWhitespace ?? true) else { return false }
        return l[..<c].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) == key
    }
    // .whitespacesAndNewlines so a CRLF file's "---\r" still counts as a fence instead of getting a second frontmatter; only an unindented fence closes.
    let isFence = { (l: String) in !(l.first?.isWhitespace ?? true) && l.trimmingCharacters(in: .whitespacesAndNewlines) == "---" }
    guard let first = lines.first, isFence(first), let end = lines.dropFirst().firstIndex(where: isFence) else {
        return value.map { "---\(eol)\n\(key): \($0)\(eol)\n---\(eol)\n" + text } ?? text
    }
    var body = Array(lines[1..<end])
    let at = body.firstIndex(where: isKey) ?? body.count
    body.removeAll(where: isKey)
    if let value { body.insert("\(key): \(value)" + eol, at: min(at, body.count)) }
    lines.replaceSubrange(1..<end, with: body)
    return lines.joined(separator: "\n")
}

// MARK: Categories and overlaps

/// Keyword buckets, first match wins. Matched against name, description and owning plugin.
private let categoryKeywords: [(String, [String])] = [
    ("Git & review", ["commit", "git", "pull request", " pr ", "review", "branch", "diff"]),
    ("Testing & debugging", ["test", "debug", "bug", "verify", "diagnos", "regression"]),
    ("Design & UI", ["design", "ui", "frontend", "css", "layout", "figma", "interface"]),
    ("Docs & writing", ["doc", "write", "writing", "readme", "markdown", "blog", "copy"]),
    ("Media", ["video", "image", "audio", "music", "voice", "animation", "diagram"]),
    ("Data & files", ["pdf", "xlsx", "spreadsheet", "csv", "docx", "pptx", "data"]),
    ("Marketing", ["marketing", "seo", "campaign", "brand", "email sequence"]),
    ("Planning & workflow", ["plan", "brainstorm", "workflow", "orchestrat", "agent", "subagent", "schedule", "loop"]),
    ("Claude config", ["claude.md", "settings", "hook", "skill", "plugin", "mcp", "config", "permission"]),
]

/// A simple keyword category for a skill; "Other" when nothing matches.
public func skillCategory(name: String, description: String, owner: String? = nil) -> String {
    let text = " " + [name.replacingOccurrences(of: "-", with: " "), description, owner ?? ""].joined(separator: " ").lowercased() + " "
    let words = Set(text.split { !$0.isLetter && $0 != "." }.map(String.init))
    for (cat, keys) in categoryKeywords where keys.contains(where: { k in
        k.contains(" ") || k.contains(".") ? text.contains(k) : k.count <= 3 ? words.contains(k) : text.contains(k)
    }) { return cat }
    return "Other"
}

extension Component {
    public var category: String { skillCategory(name: name, description: description, owner: owner) }
    /// Tool, source and reach in plain words, e.g. "Claude Code · superpowers plugin · all projects".
    public var belongsTo: String {
        func reach(_ s: String?) -> String {
            switch s { case "project": "this project only"; case "local": "this folder only"; default: "all projects" }
        }
        switch scope {
        case .user: return "Claude Code · personal · all projects"
        case .project: return "Claude Code · this project only" + (owner.map { " (" + ($0 as NSString).lastPathComponent + ")" } ?? "")
        case .external:
            if let ext = geminiExtension(self) { return "Gemini · " + ext + " extension" }
            return agents.map { $0 == .agents ? "Shared .agents folder" : $0.rawValue }.joined(separator: ", ") + " · personal"
        default: return "Claude Code · " + (owner?.split(separator: "@").first.map(String.init) ?? "") + " plugin · " + reach(pluginScope)
        }
    }
    /// The "Use when…" part of the description, else its first sentence.
    public var whenToUse: String {
        let d = description.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = d.range(of: "use (this )?(skill )?(when|whenever|for|after|before)", options: [.regularExpression, .caseInsensitive]) {
            return String(d[r.lowerBound...]).components(separatedBy: ". ").first ?? d
        }
        return d.components(separatedBy: ". ").first ?? d
    }
}

/// Two or more skills that compete: the same name in several places, or near-identical descriptions.
public struct SkillOverlap: Identifiable, Sendable {
    public enum Kind: Sendable { case sameName, similar }
    public let kind: Kind
    public let skills: [Component]
    public var id: String { skills.map(\.id).joined(separator: "|") }
    /// The copy to keep: the most used, then personal over project over plugin.
    public var keep: Component {
        skills.max { ($0.usageCount, rank($0)) < ($1.usageCount, rank($1)) }!
    }
    public var reason: String {
        kind == .sameName ? "Same /\(skills[0].shortName) in \(skills.map(\.belongsTo).joined(separator: ", "))"
                          : "Descriptions are nearly the same, so they compete for the same requests"
    }
    private func rank(_ c: Component) -> Int { c.scope == .user ? 2 : c.scope == .project ? 1 : 0 }
}

extension Component {
    /// Name without a "plugin:" prefix.
    public var shortName: String { name.split(separator: ":").last.map(String.init) ?? name }
}

/// One entry per SKILL.md: a project rooted at ~ lists ~/.claude/skills again, which is not a real duplicate.
public func uniqueSkills(_ components: [Component]) -> [Component] {
    var seen = Set<String>()
    return components.filter { $0.kind == .skill }
        .sorted { ($0.scope == .user ? 0 : 1) < ($1.scope == .user ? 0 : 1) }
        .filter { seen.insert($0.file.standardizedFileURL.resolvingSymlinksInPath().path).inserted }
}

/// Overlaps Claude Code itself sees: other agents' copies serve other tools, and one plugin's own skills are deliberate siblings.
public func skillOverlaps(_ components: [Component], threshold: Double = 0.5) -> [SkillOverlap] {
    let skills = uniqueSkills(components).filter { $0.scope != .external }
    func source(_ c: Component) -> String { c.scope == .plugin ? "plugin:" + (c.owner ?? "") : c.scope == .project ? "project:" + (c.owner ?? "") : "user" }
    var out = Dictionary(grouping: skills) { $0.shortName.lowercased() }.values
        .filter { Set($0.map(source)).count > 1 }.map { SkillOverlap(kind: .sameName, skills: $0.sorted { $0.id < $1.id }) }
    let named = Set(out.flatMap { $0.skills.map(\.id) })
    let rest = skills.filter { !named.contains($0.id) }
    for (i, a) in rest.enumerated() {
        for b in rest[(i + 1)...] where source(a) != source(b) && descriptionOverlap(a.description, b.description) >= threshold {
            out.append(SkillOverlap(kind: .similar, skills: [a, b]))
        }
    }
    return out.sorted { $0.id < $1.id }
}

/// The Gemini extension a Gemini-side skill copy comes from (~/.gemini/extensions/<name>/skills/…).
public func geminiExtension(_ c: Component) -> String? {
    let parts = c.file.pathComponents
    guard c.scope == .external, let i = parts.firstIndex(of: "extensions"), i > 0, parts[i - 1] == ".gemini", i + 1 < parts.count else { return nil }
    return parts[i + 1]
}

/// How to get rid of one copy in an overlap, titled for the confirm sheet; nil when nothing here can act on it.
/// Plugin and Gemini removals name every other skill they also take away.
public func overlapRemoval(_ s: Component, all: [Component], plugins: [Plugin]) -> (button: String, title: String, fix: Fix)? {
    func alsoRemoves(_ same: (Component) -> Bool) -> String {
        let others = uniqueSkills(all).filter { $0.id != s.id && same($0) }.map { "/" + $0.name }
        return others.isEmpty ? "" : " (also removes \(others.count): \(others.joined(separator: ", ")))"
    }
    if s.ownsFile { return ("Delete…", "Delete \(s.belongsTo) copy of /\(s.name)", .trash([trashURL(s)])) }
    if s.scope == .plugin, let id = s.owner, let p = plugins.first(where: { $0.id == id }) {
        return ("Turn off plugin…", "Turn off plugin \(id)" + alsoRemoves { $0.owner == id }, p.cli("disable"))
    }
    return nil
}

/// Keeps `keep` and removes every other copy in the overlap, one step each.
public func overlapKeepPlan(_ o: SkillOverlap, keep: Component, all: [Component], plugins: [Plugin]) -> [BulkStep] {
    o.skills.filter { $0.id != keep.id }.map { s in
        let r = overlapRemoval(s, all: all, plugins: plugins)
        return BulkStep(label: r?.title ?? "/\(s.name) (\(s.belongsTo))", fix: r?.fix, skip: r == nil ? "nothing here can remove it" : nil)
    }
}

/// Skills grouped by their "plugin:" prefix, prefixed groups by name first; un-prefixed skills last as "No prefix".
public func skillGroups(_ skills: [Component]) -> [(name: String, skills: [Component])] {
    let g = Dictionary(grouping: skills) { s in s.name.contains(":") ? String(s.name.split(separator: ":")[0]) : "" }
    return g.keys.sorted { ($0.isEmpty ? 1 : 0, $0) < ($1.isEmpty ? 1 : 0, $1) }.map { (name: $0.isEmpty ? "No prefix" : $0, skills: g[$0]!) }
}
