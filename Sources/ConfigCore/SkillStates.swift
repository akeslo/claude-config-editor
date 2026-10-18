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
    var lines = text.components(separatedBy: "\n")
    let isKey = { (l: String) in l.hasPrefix(key + ":") }
    // .whitespacesAndNewlines so a CRLF file's "---\r" still counts as a fence instead of getting a second frontmatter.
    guard lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) == "---",
          let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines) == "---" }) else {
        return value.map { "---\n\(key): \($0)\n---\n" + text } ?? text
    }
    if let i = lines[1..<end].firstIndex(where: isKey) {
        if let value { lines[i] = "\(key): \(value)" } else { lines.remove(at: i) }
    } else if let value {
        lines.insert("\(key): \(value)", at: end)
    }
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
    /// "personal", "project <folder>" or the plugin name.
    public var belongsTo: String {
        switch scope {
        case .user: "Personal"
        case .project: "Project " + (owner.map { ($0 as NSString).lastPathComponent } ?? "")
        case .external: agents.map(\.rawValue).joined(separator: ", ")
        default: "Plugin " + (owner?.split(separator: "@").first.map(String.init) ?? "")
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

public func skillOverlaps(_ components: [Component], threshold: Double = 0.5) -> [SkillOverlap] {
    let skills = uniqueSkills(components)
    var out = Dictionary(grouping: skills) { $0.shortName.lowercased() }.values
        .filter { $0.count > 1 }.map { SkillOverlap(kind: .sameName, skills: $0.sorted { $0.id < $1.id }) }
    let named = Set(out.flatMap { $0.skills.map(\.id) })
    let rest = skills.filter { !named.contains($0.id) }
    for (i, a) in rest.enumerated() {
        for b in rest[(i + 1)...] where descriptionOverlap(a.description, b.description) >= threshold {
            out.append(SkillOverlap(kind: .similar, skills: [a, b]))
        }
    }
    return out.sorted { $0.id < $1.id }
}
