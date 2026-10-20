import ConfigCore
import SwiftUI

struct MCPView: View {
    @Environment(AppModel.self) private var model
    @State private var sel = BulkSelection<String>()
    @State private var search = ""
    @State private var scope: Scope?
    @State private var sort = [KeyPathComparator(\MCPServer.name)]

    var body: some View {
        let servers = model.snapshot.mcpServers
            .filter { scope == nil || $0.scope == scope }
            .filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.description.localizedCaseInsensitiveContains(search) || $0.command.localizedCaseInsensitiveContains(search) }
            .sorted(using: sort)
        Table(servers, selection: $sel.ids, sortOrder: $sort) {
            TableColumn("Name", value: \.name) { m in
                Text(m.name).fontWeight(.medium).lineLimit(1)
                .scopeRule(ScopeMove.target(of: m).ink(fixed: m.scope == .plugin ? "Plugin" : "Managed"))
                .explains(.mcpServer, "\(m.description.isEmpty ? "" : m.description + "\n\n")Runs: \(m.command) (\(m.transport))\nFrom: \(m.scope.rawValue)")
            }
            TableColumn("Scope", value: \.scope.rawValue) { m in
                ScopeLabel(current: ScopeMove.target(of: m), fixedLabel: m.scope.rawValue)
            }.width(min: 70, ideal: 100)
            TableColumn("Where", value: \.place) { m in Text(m.place).help(m.project ?? "") }.width(140)
            TableColumn("Type", value: \.transport) { Text($0.transport) }.width(60)
            TableColumn("Command / URL", value: \.command) { Text($0.command).font(.system(.body, design: .monospaced)).lineLimit(1).truncationMode(.middle) }
        }
        .contextMenu(forSelectionType: MCPServer.ID.self) { ids in
            let picked = servers.filter { ids.contains($0.id) }
            if picked.count == 1, let m = picked.first {
                if let from = ScopeMove.target(of: m) { MoveToMenu(current: from) { t in model.moveScope(m.name, to: t) { try ScopeMove.move(mcp: m, to: t) } } }
                Button("Copy Command") { copy(m.command) }
                Divider()
                removeButton(m)
            } else if !picked.isEmpty {
                Button("Remove \(picked.count) Servers…") { removeAll(picked) }
                    .disabled(picked.allSatisfy { cliScope($0) == nil })
            }
        } primaryAction: { ids in
            if let m = servers.first(where: { ids.contains($0.id) }) { openFile(m.source) }
        }
        .searchable(text: $search, prompt: "Filter servers")
        .toolbar {
            Picker("Scope", selection: $scope) {
                Text("All scopes").tag(Scope?.none)
                ForEach(Scope.allCases, id: \.self) { Text($0.rawValue).tag(Optional($0)) }
            }
            .pickerStyle(.menu).fixedSize()
        }
        .onDeleteCommand { removeAll(servers.filter { sel.contains($0.id) }) }
        .onChange(of: sel.ids) {
            guard sel.count == 1, let m = servers.first(where: { sel.contains($0.id) }) else { return }
            model.info = InfoItem(m.name, term: .mcpServer, facts: [
                ("Scope", m.scope.rawValue), ("Project", m.project ?? "—"), ("Type", m.transport),
                ("Defined in", shortPath(m.source)),
                ("Env keys", m.env.keys.sorted().joined(separator: ", ").ifEmpty("none")),
            ], file: m.source, text: (m.description.isEmpty ? "" : m.description + "\n\n") + redacted(m.raw))
        }
    }

    private func cliScope(_ m: MCPServer) -> String? {
        switch m.scope {
        case .user: "user"
        case .local: "local"
        case .project: "project"
        default: nil
        }
    }

    private func removeAll(_ picked: [MCPServer]) {
        guard !picked.isEmpty else { return }
        model.proposeBulk("Remove \(picked.count) MCP server\(picked.count == 1 ? "" : "s")", bulkPlan(picked, label: { "\($0.name) (\($0.scope.rawValue))" }, skip: { cliScope($0) == nil ? "defined by a plugin or managed settings" : nil }) { m in
            cliScope(m).map { .cli(args: ["mcp", "remove", m.name, "-s", $0], dryRun: nil, cwd: m.project) }
        })
    }

    @ViewBuilder private func removeButton(_ m: MCPServer) -> some View {
        let cliScope = cliScope(m)
        Button("Remove \(m.name)", role: .destructive) {
            guard let cliScope else { return }
            model.propose("Remove MCP server \(m.name)", .cli(args: ["mcp", "remove", m.name, "-s", cliScope], dryRun: nil, cwd: m.project))
        }
        .disabled(cliScope == nil)
        .help(cliScope == nil ? "Defined by \(m.scope.rawValue); remove it there." : "Runs claude mcp remove in its scope. You can undo.")
    }

    /// Hide literal secret values in the side panel.
    private func redacted(_ raw: String) -> String {
        raw.split(separator: "\n").map { line in
            let l = line.lowercased()
            guard ["key", "token", "secret", "password", "auth"].contains(where: l.contains), line.contains(":"), !line.contains("${") else { return String(line) }
            return line.split(separator: ":", maxSplits: 1)[0] + ": \"••••••\""
        }.joined(separator: "\n")
    }
}

struct ComponentsView: View {
    @Environment(AppModel.self) private var model
    @State private var sel = BulkSelection<String>()
    @State private var kind: ComponentKind?
    @State private var search = ""
    @State private var sort = [KeyPathComparator(\Row.tokens, order: .reverse)]

    struct Row: Identifiable {
        let c: Component
        var id: String { c.id }
        var name: String { c.name }
        var tokens: Int { c.listingTokens }
        var uses: Int { c.usageCount }
        var lines: Int { c.lineCount }
        var last: Date { c.lastUsed ?? .distantPast }
    }

    var body: some View {
        // Skills live on the Skills page; this one is agents, commands and output styles.
        let rows = model.snapshot.components
            .filter { $0.kind != .skill && (kind == nil || $0.kind == kind) }
            .filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.description.localizedCaseInsensitiveContains(search) }
            .map(Row.init).sorted(using: sort)
        Table(rows, selection: $sel.ids, sortOrder: $sort) {
            TableColumn("Name", value: \.name) { r in
                Text(r.name).fontWeight(.medium).lineLimit(1)
                .scopeRule(ScopeMove.target(of: r.c).ink(fixed: r.c.scope == .plugin ? "Plugin" : "Managed"))
                .explains(r.c.kind.term, "\(r.c.description)\n\nFrom: \(origin(r.c))")
            }
            TableColumn("Description") { Text($0.c.description).foregroundStyle(.secondary).lineLimit(1) }.width(min: 120, ideal: 360)
            TableColumn("Type") { Text($0.c.kind.rawValue) }.width(80)
            TableColumn("Scope") { r in
                ScopeLabel(current: ScopeMove.target(of: r.c), fixedLabel: r.c.scope == .plugin ? "Plugin" : r.c.scope.rawValue)
            }.width(min: 70, ideal: 100)
            TableColumn("Listed", value: \.tokens) { r in
                Text(r.c.override == "user-invocable-only" ? "hidden" : r.tokens == 0 ? "on demand" : formatTokens(r.tokens)).monospacedDigit()
                    .help(Term.skillListing.tooltip)
            }.width(80)
            TableColumn("Uses", value: \.uses) { Text("\($0.uses)").monospacedDigit() }.width(50)
            TableColumn("Last used", value: \.last) { Text(relative($0.c.lastUsed)) }.width(110)
            TableColumn("Lines", value: \.lines) { r in Text("\(r.lines)").monospacedDigit().foregroundStyle(r.lines > 500 ? Ink.warning : .primary) }.width(50)
        }
        .contextMenu(forSelectionType: Component.ID.self) { ids in
            let picked = model.snapshot.components.filter { ids.contains($0.id) }
            if picked.count == 1, let c = picked.first {
                Button("Open") { openFile(c.file) }
                if let from = ScopeMove.target(of: c) {
                    MoveToMenu(current: from, allowLocal: false) { t in model.moveScope(c.name, to: t) { try ScopeMove.move(component: c, to: t) } }
                }
                Divider()
            }
            trashButton(picked)
        } primaryAction: { ids in
            if let c = model.snapshot.components.first(where: { ids.contains($0.id) }) { openFile(c.file) }
        }
        .onDeleteCommand { trash(model.snapshot.components.filter { sel.contains($0.id) }) }
        .searchable(text: $search, prompt: "Filter by name or description")
        .toolbar {
            Picker("Kind", selection: $kind) {
                Text("All").tag(ComponentKind?.none)
                ForEach(ComponentKind.allCases.filter { $0 != .skill }, id: \.self) { Text($0.rawValue + "s").tag(Optional($0)) }
            }
            .pickerStyle(.menu).fixedSize()
        }
        .onChange(of: sel.ids) {
            guard let c = selected else { return }
            model.info = InfoItem(c.name, term: c.kind.term, facts: [
                ("Scope", c.scope.rawValue), ("From", c.owner ?? "personal"),
                ("Always listed", c.listingTokens > 0 ? "Yes, \(formatTokens(c.listingTokens))" : "No"),
                ("Override", c.override ?? "none"), ("Uses", "\(c.usageCount)"), ("Last used", relative(c.lastUsed)),
                ("Lines", "\(c.lineCount)"), ("Frontmatter", c.frontmatterKeys.joined(separator: ", ")),
            ], file: c.file, text: fileText(c.file) ?? c.description)
            model.info?.link = model.snapshot.plugins.first { $0.id == c.owner }?.repoURL
        }
    }

    private var selected: Component? { sel.count == 1 ? model.snapshot.components.first { sel.contains($0.id) } : nil }

    @ViewBuilder private func trashButton(_ picked: [Component]) -> some View {
        let check = bulkCheck(picked) { $0.ownsFile ? nil : "come from plugins or other agents" }
        Button(picked.count == 1 ? "Move to Trash" : "Move \(picked.count) to Trash", role: .destructive) { trash(picked) }
            .disabled(!check.enabled).help(check.why ?? "You can undo.")
    }

    private func trash(_ picked: [Component]) {
        guard !picked.isEmpty else { return }
        model.proposeBulk("Move \(picked.count) item\(picked.count == 1 ? "" : "s") to the Trash", bulkPlan(picked, label: { "\($0.kind.rawValue): \($0.name)" }) { $0.ownsFile ? .trash([trashURL($0)]) : nil })
    }
}


struct PluginsView: View {
    @Environment(AppModel.self) var model
    @State private var sel = BulkSelection<String>()
    @State private var search = ""
    @State private var sort = [KeyPathComparator(\Plugin.id)]

    var body: some View {
        let plugins = model.snapshot.plugins
            .filter { search.isEmpty || $0.id.localizedCaseInsensitiveContains(search) || $0.description.localizedCaseInsensitiveContains(search) }
            .sorted(using: sort)
        Table(plugins, selection: $sel.ids, sortOrder: $sort) {
            TableColumn("Plugin", value: \.id) { p in
                HStack {
                    Image(systemName: p.enabled ? "checkmark.circle.fill" : "circle").foregroundStyle(p.enabled ? Ink.success : .secondary)
                        .help(p.enabled ? "Enabled" : "Disabled: costs no context")
                    Text(p.id).fontWeight(.medium).lineLimit(1)
                        .explains(.plugin, (p.description.isEmpty ? "" : p.description + "\n\n") + "From marketplace: \(p.marketplace)" + (p.repoURL.map { "\nSource: \($0.absoluteString)" } ?? ""))
                    if !p.notes.isEmpty { Image(systemName: "exclamationmark.bubble").foregroundStyle(Ink.warning).help(p.notes.joined(separator: "\n")) }
                }
                .scopeRule(ScopeMove.target(ofPlugin: p).ink(fixed: "Managed"))
            }
            TableColumn("Description") { Text($0.description).foregroundStyle(.secondary).lineLimit(1) }.width(min: 120, ideal: 320)
            TableColumn("Scope", value: \.scope) { p in
                ScopeLabel(current: ScopeMove.target(ofPlugin: p), fixedLabel: p.scope.capitalized)
            }.width(min: 70, ideal: 100)
            TableColumn("Version", value: \.version) { p in
                if let v = p.latestVersion {
                    Label("\(p.version.prefix(12)) → \(v)", systemImage: "arrow.up.circle.fill").foregroundStyle(Ink.accent).lineLimit(1)
                        .help("Update available: right-click › Update")
                } else { Text(p.version).lineLimit(1) }
            }.width(150)
            TableColumn("Always-on") { p in
                Text(p.enabled ? model.pluginTokens[p.id].map(formatTokens) ?? "…" : "—").monospacedDigit()
                    .help("Context added to every session, from claude plugin details")
            }.width(90)
            TableColumn("Uses", value: \.usageCount) { Text("\($0.usageCount)").monospacedDigit() }.width(50)
            TableColumn("Last used", value: \.lastUsed, comparator: OptionalDateComparator()) { Text(relative($0.lastUsed)) }.width(110)
        }
        .overlay {
            if model.snapshot.plugins.isEmpty && !model.loading {
                ContentUnavailableView("No plugins installed", systemImage: "puzzlepiece.extension", description: Text("Install one with claude plugin install <name>@<marketplace>."))
            }
        }
        .searchable(text: $search, prompt: "Filter plugins")
        .contextMenu(forSelectionType: Plugin.ID.self) { ids in
            let picked = plugins.filter { ids.contains($0.id) }
            if !picked.isEmpty {
                Button("Turn On", action: cli(picked, "enable") { $0.enabled ? "already enabled" : nil }).disabled(picked.allSatisfy(\.enabled))
                Button("Turn Off", action: cli(picked, "disable") { $0.enabled ? nil : "already disabled" }).disabled(!picked.contains(where: \.enabled))
                Button("Update…", action: cli(picked, "update"))
                if picked.count == 1, let p = picked.first, let from = ScopeMove.target(ofPlugin: p) {
                    MoveToMenu(current: from) { t in model.movePlugin(p, to: t) }
                }
                Divider()
                Button("Uninstall…", role: .destructive, action: cli(picked, "uninstall"))
            }
        } primaryAction: { ids in
            if let p = plugins.first(where: { ids.contains($0.id) }) { reveal(p.installPath) }
        }
        .onChange(of: sel.ids) {
            guard let p = plugins.first(where: { sel.contains($0.id) }) else { return }
            let parts = model.snapshot.components.filter { $0.owner == p.id }
            model.info = InfoItem(p.id, term: .plugin, facts: [
                ("Enabled", p.enabled ? "Yes" : "No"), ("Version", p.version), ("Scope", p.scope), ("Marketplace", p.marketplace),
                ("Always-on", model.pluginTokens[p.id].map(formatTokens) ?? "—"), ("Uses", "\(p.usageCount)"),
            ], file: p.installPath, link: p.repoURL, text: (p.description.isEmpty ? "" : p.description + "\n\n") + (parts.isEmpty ? "" : "Contains:\n" + parts.map { "\($0.kind.rawValue): \($0.name)" }.joined(separator: "\n")) + (p.notes.isEmpty ? "" : "\n\nNotes:\n" + p.notes.joined(separator: "\n")))
        }
    }
}

extension PluginsView {
    func cli(_ picked: [Plugin], _ verb: String, skip: @escaping (Plugin) -> String? = { _ in nil }) -> () -> Void {
        { model.proposeBulk("\(verb.capitalized) \(picked.count) plugin\(picked.count == 1 ? "" : "s")", bulkPlan(picked, label: \.id, skip: skip) { $0.cli(verb) }) }
    }
}

struct HooksView: View {
    @Environment(AppModel.self) private var model
    @State private var sel = BulkSelection<UUID>()
    @State private var search = ""

    var body: some View {
        let hooks = model.snapshot.hooks
            .filter { search.isEmpty || $0.command.localizedCaseInsensitiveContains(search) || $0.event.localizedCaseInsensitiveContains(search) || $0.source.localizedCaseInsensitiveContains(search) || ($0.matcher ?? "").localizedCaseInsensitiveContains(search) }
        // One row per (source, command): the same program on several events is one tool reporting several moments. Its id is its first hook's.
        let rows = Dictionary(grouping: hooks) { $0.source + "\u{0}" + $0.command }.values
            .map { HookRow(hooks: $0) }
            .sorted { ($0.first.source.hasPrefix("Plugin") ? 1 : 0, $0.first.source, $0.name) < ($1.first.source.hasPrefix("Plugin") ? 1 : 0, $1.first.source, $1.name) }
        Table(rows, selection: $sel.ids) {
            TableColumn("Hook") { (r: HookRow) in
                HStack(spacing: 4) {
                    Text(r.name).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                    if let s = r.first.scriptPath, !exists(s) { Image(systemName: "xmark.octagon").foregroundStyle(Ink.danger).help("Broken: script missing") }
                }
                .scopeRule(ScopeMove.target(ofSettings: r.first.sourceURL).ink(fixed: r.first.source.hasPrefix("Plugin") ? "Plugin" : "Managed"))
                .help(r.first.command)
            }.width(min: 140, ideal: 200)
            TableColumn("Runs") { (r: HookRow) in Text(r.hooks.map { when($0) }.joined(separator: " · ")).lineLimit(1).help(r.hooks.map { eventHelp($0.event) }.joined(separator: "\n")) }
                .width(min: 160, ideal: 300)
            TableColumn("Effect") { (r: HookRow) in Text(effect(r.hooks)).foregroundStyle(.secondary).lineLimit(1) }.width(min: 90, ideal: 170)
            TableColumn("Where") { (r: HookRow) in Text(whereRuns(r.first).text).foregroundStyle(.secondary).lineLimit(1).help(r.first.source) }.width(min: 90, ideal: 150)
            TableColumn("What it does") { (r: HookRow) in
                let key = model.explanationKey(r.first)
                Group {
                    if model.explaining.contains(key) { Text("Asking Claude…") }
                    else if let p = purpose(r.first) { Text(p) }
                    // Shown only when the hook has no description of its own: a script can try to steer the model.
                    else if let guess = model.hookExplanations[key] { Text("AI guess: " + guess).italic() }
                    else { Text("No description. Right-click › Explain with Claude") }
                }
                .foregroundStyle(.secondary).lineLimit(1)
            }.width(min: 160, ideal: 420)
        }
        .contextMenu(forSelectionType: Hook.ID.self) { ids in
            // A row's tag is its first hook; act on every event that row stands for.
            let rowCommands = Set(hooks.filter { ids.contains($0.id) }.map { $0.source + "\u{0}" + $0.command })
            let picked = hooks.filter { rowCommands.contains($0.source + "\u{0}" + $0.command) }
            if let h = picked.first {
                Button("Open Settings File") { openFile(h.sourceURL) }
                Button("Reveal in Finder") { reveal(h.scriptPath.flatMap { exists($0) ? $0 : nil } ?? h.sourceURL) }
                Button("Copy Command") { copy(Set(picked.map(\.command)).sorted().joined(separator: "\n")) }
                Button("Explain with Claude") { Task { await model.explain(h) } }
            }
            // Plugin hooks live in the plugin; turning the plugin off is how to stop them.
            let removable = picked.filter { !$0.source.hasPrefix("Plugin") }
            if !removable.isEmpty {
                Button(rowCommands.count == 1 ? "Remove Hook" : "Remove \(rowCommands.count) Hooks") {
                    model.propose("Remove \(removable.count) hook entr\(removable.count == 1 ? "y" : "ies")", .removeHooks(removable.map { HookRef(file: $0.sourceURL, event: $0.event, matcher: $0.matcher, command: $0.command) }))
                }
            }
            if let h = picked.first, let from = ScopeMove.target(ofSettings: h.sourceURL), rowCommands.count == 1 {
                MoveToMenu(current: from) { t in model.moveScope("\(h.event) hook", to: t) { try ScopeMove.move(hook: h, to: t) } }
            }
            TrashButton(urls: Array(Set(picked.compactMap(\.scriptPath).filter(exists))), label: "Move Script to Trash")
        } primaryAction: { ids in
            if let h = hooks.first(where: { ids.contains($0.id) }) { openFile(h.scriptPath.flatMap { exists($0) ? $0 : nil } ?? h.sourceURL) }
        }
        .searchable(text: $search, prompt: "Filter hooks by command, event or source")
        .onChange(of: sel.ids) {
            guard let h = hooks.first(where: { sel.contains($0.id) }) else { return }
            model.info = InfoItem("\(h.event) hook", term: .hook, facts: [
                ("Event", h.event), ("Matcher", h.matcher ?? "all"), ("Source", h.source), ("Async", h.async ? "Yes" : "No"),
                ("Adds to context", ["SessionStart", "UserPromptSubmit"].contains(h.event) ? "Can (its output)" : "No"),
            ], file: h.sourceURL, link: hookPlugin(h)?.repoURL,
               text: h.command + (h.scriptPath.flatMap(fileText).map { "\n\n── \(shortPath(h.scriptPath!)) ──\n" + $0 } ?? ""))
        }
    }

    private func hookPlugin(_ h: Hook) -> Plugin? {
        model.snapshot.plugins.first { h.source == "Plugin · \($0.id)" }
    }

    /// What the hook can do to a session, in words (background hooks can't block or add context).
    private func effect(_ same: [Hook]) -> String {
        let waits = same.filter { !$0.async }
        var out: [String] = []
        if waits.contains(where: { ["SessionStart", "UserPromptSubmit"].contains($0.event) }) { out.append("may add context") }
        if waits.contains(where: { $0.event == "PreToolUse" }) { out.append("may block tools") }
        if same.allSatisfy(\.async) { out.append("background") }
        return out.joined(separator: ", ").ifEmpty("—")
    }

    /// Which sessions this hook fires in.
    private func whereRuns(_ h: Hook) -> (text: String, everywhere: Bool) {
        if let p = hookPlugin(h) { return p.scope == "user" ? ("Every project", true) : ("Only where \(p.id.split(separator: "@").first ?? "") is installed", false) }
        if h.source.hasPrefix("User") || h.source.hasPrefix("Managed") { return ("Every project", true) }
        let project = h.source.components(separatedBy: " · ").last ?? h.source
        return ("Only in \(project)", false)
    }

    /// What the hook is for: the script's opening comment, else its plugin's description.
    private func purpose(_ h: Hook) -> String? {
        if let s = h.scriptPath, let text = try? String(contentsOf: s, encoding: .utf8) {
            let comment = text.split(separator: "\n").prefix(20).map { $0.trimmingCharacters(in: .whitespaces) }
                .drop { $0.hasPrefix("#!") || $0.isEmpty }
                .prefix { $0.hasPrefix("#") || $0.hasPrefix("//") }
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "#/ ")) }.filter { !$0.isEmpty }
            if !comment.isEmpty { return comment.joined(separator: " ") }
        }
        if let d = hookPlugin(h)?.description, !d.isEmpty { return d }
        // Only the program being run counts, and only when it exists, so text elsewhere in the command can't claim an app.
        let cmd = h.command.trimmingCharacters(in: .whitespaces)
        let exe = cmd.hasPrefix("\"") ? String(cmd.dropFirst().prefix { $0 != "\"" }) : String(cmd.prefix { $0 != " " })
        if exe.hasPrefix("/"), exists(URL(filePath: exe)), let app = exe.range(of: #"^/(?:[^/]+/)*?([^/]+\.app)/"#, options: .regularExpression) {
            return "Part of \(URL(filePath: String(exe[app])).lastPathComponent)."
        }
        return nil
    }

    /// Plain-English trigger, e.g. "Before Claude uses Bash".
    private func when(_ h: Hook) -> String {
        let tool = (h.matcher ?? "").ifEmpty("*") == "*" ? "any tool" : h.matcher!
        return switch h.event {
        case "SessionStart": "When a session starts"
        case "UserPromptSubmit": "Every time you send a prompt"
        case "PreToolUse": "Before Claude uses \(tool)"
        case "PostToolUse": "After Claude uses \(tool)"
        case "Stop": "When Claude finishes replying"
        case "Notification": "When Claude needs your attention"
        default: "On \(h.event)"
        }
    }

    private func eventHelp(_ e: String) -> String {
        switch e {
        case "SessionStart": "Runs when a session starts or resumes. Its output is added to the context."
        case "UserPromptSubmit": "Runs on every prompt you send. Its output is added to the context."
        case "PreToolUse": "Runs before a tool call and can block it."
        case "PostToolUse": "Runs after a tool call succeeds."
        case "Stop": "Runs when Claude finishes replying."
        case "Notification": "Runs when Claude needs your attention."
        default: Term.hook.tooltip
        }
    }
}

private struct HookRow: Identifiable {
    let hooks: [Hook]
    var first: Hook { hooks[0] }
    var id: UUID { first.id }
    var name: String { first.scriptPath?.lastPathComponent ?? first.command }
}

extension MCPServer {
    var place: String { project.map { ($0 as NSString).lastPathComponent } ?? "everywhere" }
}

extension ComponentKind {
    var term: Term { switch self { case .skill: .skill; case .subagent: .subagent; case .command: .command; case .outputStyle: .outputStyle } }
}

/// A definition file's text for the side panel, capped so huge files stay responsive.
func fileText(_ url: URL) -> String? {
    guard let t = try? String(contentsOf: url, encoding: .utf8) else { return nil }
    return t.count > 20_000 ? String(t.prefix(20_000)) + "\n…" : t
}

/// Human-readable source for hover text, instead of the raw scope name.
private func origin(_ c: Component) -> String {
    switch c.scope {
    case .plugin: "the plugin \(c.owner ?? "")"
    case .user, .userLocal: "your personal files (~/.claude)"
    case .project, .local: "the project " + ((c.owner as NSString?)?.lastPathComponent ?? "folder")
    case .managed: "your administrator (managed settings)"
    case .desktop: "Claude Desktop"
    case .external: c.owner.map { "another agent (\($0))" } ?? "another agent"
    }
}
extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}

struct OptionalDateComparator: SortComparator {
    var order: SortOrder = .forward
    func compare(_ a: Date?, _ b: Date?) -> ComparisonResult {
        let r = (a ?? .distantPast).compare(b ?? .distantPast)
        return order == .forward ? r : (r == .orderedAscending ? .orderedDescending : r == .orderedDescending ? .orderedAscending : .orderedSame)
    }
}
