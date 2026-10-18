import Foundation

/// Everything "Ask Claude" sends about the screen a question comes from: the app's own label definitions, every row the
/// screen is built from (with source, path, usage, staleness, failures), secrets masked, and an explicit note of anything trimmed.
public enum ScreenContext {
    /// Character budget for the data block (~4 chars/token, so ≈20k tokens).
    public static let defaultBudget = 80_000
    public static let descriptionCap = 300

    /// The app's own labels, so Claude can explain them in the app's terms.
    public static let glossary: [(String, String)] = [
        ("Always available", SkillState.always.explanation),
        ("On demand", SkillState.onDemand.explanation + " (disable-model-invocation: true, or skillOverrides user-invocable-only)"),
        ("Off", SkillState.off.explanation + " (skillOverrides off)"),
        ("Your skills", "Skills page tab listing EVERY personal, project and plugin skill with its state picker (Always available / On demand / Off) and suggestions. It includes the on-demand ones."),
        ("My on-demand skills", "Skills page tab: a cheat sheet of only the skills whose state is On demand, so you remember to type /name. It is a subset of Your skills, so the two always overlap by design."),
        ("Skill map", "Skills page tab: bubbles sized by times used (from ~/.claude.json skillUsage); faded = On demand, struck = Off."),
        ("source", "user = ~/.claude, project = <repo>/.claude, plugin = shipped by an installed plugin (follows the plugin being on/off)."),
        ("stale", "Not modified in >90 days, not used in >60 days, or its path is missing; aging = halfway there."),
        ("tokens", "Estimated at ~4 characters per token; an always-available skill costs its name+description every session."),
        ("Agents & Commands", "Subagents (~/.claude/agents), slash commands (~/.claude/commands) and output styles."),
        ("Memory", "CLAUDE.md, CLAUDE.local.md, rules and auto-memory MEMORY.md files Claude loads into context."),
        ("Problems & Cleanup", "Review tab listing things that failed to load (broken skills, missing plugin files, non-executable hook scripts, missing MCP commands, invalid JSON) and stale items to clean up."),
    ]

    /// What the Discover screen shows that isn't in the Snapshot: marketplace plugins, community skills, tab and search box.
    public struct Discover: Sendable {
        public var tab: String, search: String
        public var available: [AvailablePlugin], community: [CommunitySkill]
        public var communityInstalled: Set<String>  // CommunitySkill ids
        public init(tab: String, search: String, available: [AvailablePlugin], community: [CommunitySkill], communityInstalled: Set<String>) {
            self.tab = tab; self.search = search; self.available = available; self.community = community; self.communityInstalled = communityInstalled
        }
    }

    /// Per-list caps for itemised screens: one line per item, short descriptions.
    public static let listCap = 150, shortDescription = 120
    static let stopwords: Set<String> = ["the", "and", "for", "are", "any", "you", "your", "with", "about", "looking", "find", "show",
                                         "what", "which", "have", "there", "this", "that", "skill", "skills", "plugin", "plugins", "across", "like", "some"]

    /// Lowercased words worth matching, with a trailing plural "s" dropped.
    static func terms(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
            .filter { $0.count >= 3 && !stopwords.contains($0) }
            .map { $0.count > 3 && $0.hasSuffix("s") ? String($0.dropLast()) : $0 }
    }

    /// Best match first (name hits count triple), ties keep `items`' order; no terms keeps the order.
    static func rank<T>(_ items: [T], _ terms: [String], name: (T) -> String, rest: (T) -> String) -> [T] {
        guard !terms.isEmpty else { return items }
        func score(_ x: T) -> Int {
            let n = name(x).lowercased(), r = rest(x).lowercased()
            return terms.reduce(0) { $0 + (n.contains($1) ? 3 : 0) + (r.contains($1) ? 1 : 0) }
        }
        return items.enumerated().map { ($0.offset, score($0.element), $0.element) }
            .sorted { ($0.1, -$0.0) > ($1.1, -$1.0) }.map(\.2)
    }

    public static func build(_ section: AppSection, _ s: Snapshot, issues: [Issue], advice: Advice, storage: [StorageArea] = [],
                             discover: Discover? = nil, analytics: AnalyticsReport? = nil, question: String = "",
                             now: Date = Date(), budget: Int = defaultBudget) -> String {
        var trimmed = 0
        func strip(_ v: String) -> String { String(String.UnicodeScalarView(v.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })) }
        func c(_ v: String) -> String { redact(strip(v)) }
        func desc(_ v: String) -> String {
            let t = c(v)
            guard t.count > descriptionCap else { return t }
            trimmed += 1
            return String(t.prefix(descriptionCap)) + "…[trimmed]"
        }
        func ago(_ d: Date?) -> String { d.map { "\(Int(now.timeIntervalSince($0) / 86_400))d ago" } ?? "never" }
        func day(_ d: Date?) -> String { d.map { $0.formatted(.iso8601.year().month().day()) } ?? "?" }
        let failing = Dictionary(grouping: issues.filter { $0.severity == .problem }, by: { $0.file?.path ?? $0.subject })
        func failure(_ keys: String...) -> String {
            let hits = keys.flatMap { failing[$0] ?? [] }
            return hits.isEmpty ? "ok" : "FAILED: " + hits.map { c($0.title) }.joined(separator: "; ")
        }

        func inventory() -> [String] {
            var l = ["## Skills, agents, commands, output styles (\(s.components.count))",
                     "kind | name | source | owner | state | listing tokens | used | last used | staleness | status | path | description"]
            for x in s.components.sorted(by: { ($0.kind.rawValue, $0.name) < ($1.kind.rawValue, $1.name) }) {
                let st = Staleness.of(modified: fileDates(x.file).modified, lastUsed: x.kind == .skill ? (x.lastUsed ?? x.installedAt) : nil, now: now)
                l.append("\(x.kind.rawValue) | \(c(x.name)) | \(x.scope.rawValue) | \(c(x.owner ?? "-")) | \(x.state.rawValue) | \(x.listingTokens) | \(x.usageCount)x | \(ago(x.lastUsed)) | \(st.level)\(st.reason.isEmpty ? "" : " (\(st.reason))") | \(failure(x.file.path, x.file.deletingLastPathComponent().path)) | \(c(shortPath(x.file))) | \(desc(x.description))")
            }
            l += ["", "## MCP servers (\(s.mcpServers.count))", "name | scope | project | transport | command | env names | header names | status | defined in | description"]
            for m in s.mcpServers {
                l.append("\(c(m.name)) | \(m.scope.rawValue) | \(c(m.project ?? "-")) | \(c(m.transport)) | \(c(m.command)) | \(m.env.keys.sorted().map(c).joined(separator: ",")) | \(m.headers.keys.sorted().map(c).joined(separator: ",")) | \(failure(m.source.path, "\(m.name) · \(shortPath(m.source))")) | \(c(shortPath(m.source))) | \(desc(m.description))")
            }
            l += ["", "## Plugins (\(s.plugins.count))", "id | version | enabled | used | last used | always-on tokens | status | install path | description"]
            for p in s.plugins {
                l.append("\(c(p.id)) | \(c(p.version)) | \(p.enabled ? "enabled" : "disabled") | \(p.usageCount)x | \(ago(p.lastUsed)) | \(p.alwaysOnTokens.map(String.init) ?? "?") | \(failure(p.id)) | \(c(shortPath(p.installPath))) | \(desc(p.description))")
            }
            l += ["", "## Hooks (\(s.hooks.count))", "event | matcher | command | async | source | script | status"]
            for h in s.hooks {
                l.append("\(c(h.event)) | \(c(h.matcher ?? "*")) | \(desc(h.command)) | \(h.async) | \(c(h.source)) | \(h.scriptPath.map { c(shortPath($0)) } ?? "-") | \(failure(h.sourceURL.path))")
            }
            return l
        }

        func memory() -> [String] {
            var l = ["## Memory files, grouped by project (tokens loaded, created, modified, staleness)"]
            for (project, files) in Dictionary(grouping: s.instructions, by: { $0.project ?? "~ (user)" }).sorted(by: { $0.key < $1.key }) {
                l.append("\(c(project.replacingOccurrences(of: Paths.home.path, with: "~")))/")
                for f in files.sorted(by: { $0.url.path < $1.url.path }) {
                    let d = fileDates(f.url), st = Staleness.of(modified: d.modified, now: now)
                    l.append("  \(f.kind.rawValue) \(c(shortPath(f.url))) | \(f.tokens) tokens | \(f.lines) lines\(f.pathScoped ? " | path-scoped" : "") | created \(day(d.created)) | modified \(day(d.modified)) | \(st.level)\(f.problems.isEmpty ? "" : " | problems: " + f.problems.map(c).joined(separator: "; "))")
                }
            }
            return l
        }

        func short(_ v: String) -> String {
            let t = c(v).replacingOccurrences(of: "|", with: "/")
            return t.count > shortDescription ? String(t.prefix(shortDescription)) + "…" : t
        }
        /// One line per item, capped at `listCap` with a "+N more" note.
        func list<T>(_ title: String, _ items: [T], _ line: (T) -> String) -> [String] {
            let shown = items.prefix(listCap).map(line)
            return ["## \(title) (\(items.count))"] + (shown.isEmpty ? ["(none)"] : shown)
                + (items.count > listCap ? ["+\(items.count - listCap) more not shown (lower relevance); suggest a narrower search."] : [])
        }

        func discoverData() -> [String] {
            let d = discover ?? Discover(tab: "plugins", search: "", available: [], community: [], communityInstalled: [])
            let t = terms(d.search + " " + question)
            var l = ["## Discover screen state",
                     "active tab: \(d.tab == "community" ? "Community skills" : "Plugins (marketplace)")",
                     "search filter: \(d.search.isEmpty ? "(none)" : "\"" + c(d.search) + "\"")",
                     t.isEmpty ? "Lists below are in the screen's order." : "Lists below are ranked by relevance to: \(t.joined(separator: ", "))", ""]
            let avail = rank(d.available.sorted { $0.installCount > $1.installCount }, t, name: \.name, rest: { $0.description + " " + $0.marketplace })
            l += list("Marketplace plugins: name | marketplace | installs | installed | description", avail) {
                "\(c($0.name)) | \(c($0.marketplace)) | \($0.installCount) | \($0.installed ? "installed" : "not installed") | \(short($0.description))"
            }
            if d.available.isEmpty { l.append("(marketplace list not loaded yet)") }
            let comm = rank(d.community, t, name: \.name, rest: { $0.description + " " + $0.category })
            l += [""] + list("Community skills: name | category | list | stars | installed | description", comm) {
                "\(c($0.name)) | \(c($0.category)) | \(c($0.list)) | \($0.stars.map(String.init) ?? "-") | \(d.communityInstalled.contains($0.id) ? "installed" : "not installed") | \(short($0.description))"
            }
            if d.community.isEmpty { l.append("(community lists not loaded yet)") }
            let mine = rank(s.components.sorted { $0.name < $1.name }, t, name: \.name, rest: \.description)
            l += [""] + list("Your installed skills, agents, commands: kind | name | source | agents | description", mine) {
                "\($0.kind.rawValue) | \(c($0.name)) | \($0.scope.rawValue) | \($0.agents.map(\.rawValue).joined(separator: ", ")) | \(short($0.description))"
            }
            let plugins = rank(s.plugins, t, name: \.id, rest: \.description)
            l += [""] + list("Your installed plugins: id | enabled | description", plugins) {
                "\(c($0.id)) | \($0.enabled ? "enabled" : "disabled") | \(short($0.description))"
            }
            return l
        }

        func analyticsData() -> [String] {
            guard let a = analytics else { return ["## Analytics", "(session analytics not computed yet)"] }
            var l = ["## Analytics: \(a.sessions.count) sessions, \(a.totalTokens) tokens, \(a.compactions) compactions, cache hit \(Int(a.cacheHitRate * 100))%",
                     "", "## Top tools: name | calls"] + a.topTools(30).map { "\(c($0.name)) | \($0.count)" }
            l += ["", "## Per day (last 60 days): day | sessions | tokens"] + a.perDay().map { "\(day($0.day)) | \($0.sessions) | \($0.tokens)" }
            let recent = a.sessions.sorted { ($0.start ?? .distantPast) > ($1.start ?? .distantPast) }
            l += [""] + list("Sessions, newest first: start | project | title | tokens | requests", recent) {
                "\(day($0.start)) | \(c($0.project)) | \(short($0.title ?? "-")) | \($0.totalTokens) | \($0.requests)"
            }
            return l
        }

        var data: [String]
        switch section {
        case .discover:
            data = discoverData()
        case .analytics:
            data = analyticsData() + [""] + inventory()
        case .mySkills, .skills, .plugins, .mcp, .hooks:
            data = inventory()
        case .instructions:
            data = memory()
        case .context:
            data = memory() + [""] + inventory()
        case .storage:
            data = ["## Storage areas", "name | path | safety | auto-cleaned | bytes | items | oldest"]
                + storage.map { "\(c($0.name)) | \(c(shortPath($0.url))) | \($0.safety.rawValue) | \($0.autoCleaned) | \($0.bytes) | \($0.itemCount) | \(day($0.oldest))" }
        case .projects:
            data = ["## Projects", "path | exists | trusted | transcripts | bytes | last session | staleness"]
                + s.projects.map { p in
                    "\(c(p.path)) | \(p.folderExists) | \(p.trusted) | \(p.transcriptCount) | \(p.dataBytes) | \(day(p.lastSession)) | \(Staleness.of(lastUsed: p.lastSession, pathExists: p.folderExists, now: now).level)"
                }
        case .health:
            data = ["## Findings", "severity | category | title | where | detail"]
                + issues.map { "\($0.severity) | \($0.category.title) | \(c($0.title)) | \(c($0.subject)) | \(desc($0.detail))" }
                + ["", "## Stale items"] + Failures.stale(s, now: now).map { "\(c($0.name)) | \($0.reason)" }
        default:
            data = [screenText(section, s, issues: issues, advice: advice)]
        }
        let problems = issues.filter { $0.severity == .problem }
        if section != .health, !problems.isEmpty {
            data += ["", "## Problems detected anywhere (\(problems.count))"] + problems.map { "\(c($0.title)) | \(c($0.subject))" }
        }

        var body = data.joined(separator: "\n")
        var notes: [String] = []
        if trimmed > 0 { notes.append("\(trimmed) descriptions/commands longer than \(descriptionCap) characters were trimmed (marked …[trimmed]); read the file at its path for the full text.") }
        if body.count > budget {
            let kept = String(body.prefix(budget)), cut = body.count - kept.count
            body = kept[..<(kept.lastIndex(of: "\n") ?? kept.endIndex)] + ""
            notes.append("The data was over the \(budget)-character budget; the last \(cut)+ characters (remaining rows) were omitted. Read files under ~/.claude for the rest.")
        }
        notes.append("Secret values (env, headers, tokens, keys, URL credentials) are masked as *** or omitted; only names are shown.")
        let header = ["# Screen: \(section.rawValue)", "## What this app's labels mean"] + glossary.map { "- \($0.0): \($0.1)" }
        return (header + [""] + ["## Notes about this data"] + notes.map { "- " + $0 } + [""] + [body]).joined(separator: "\n")
    }
}
