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
        let visible = servers.map(\.id)
        let picked = servers.filter { sel.contains($0.id) } + model.snapshot.mcpServers.filter { sel.contains($0.id) && !visible.contains($0.id) }
        Table(servers, selection: $sel.ids, sortOrder: $sort) {
            TableColumn("", value: \MCPServer.name) { (m: MCPServer) in SelectBox(sel: $sel, id: m.id, visible: visible, name: m.name) }.width(22)
            TableColumn("Name", value: \.name) { m in
                VStack(alignment: .leading) {
                    Text(m.name).fontWeight(.medium)
                    if !m.description.isEmpty { Text(m.description).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
                .explains(.mcpServer, "\(m.description.isEmpty ? "" : m.description + "\n\n")Runs: \(m.command) (\(m.transport))\nFrom: \(m.scope.rawValue)")
            }
            TableColumn("Scope", value: \.scope.rawValue) { m in
                ScopeMenu(current: ScopeMove.target(of: m), fixedLabel: m.scope.rawValue) { t in model.moveScope(m.name, to: t) { try ScopeMove.move(mcp: m, to: t) } }
            }.width(min: 110, ideal: 120)
            TableColumn("Where", value: \.place) { m in Text(m.place).help(m.project ?? "") }.width(140)
            TableColumn("Type", value: \.transport) { Text($0.transport) }.width(60)
            TableColumn("Command / URL", value: \.command) { Text($0.command).font(.system(.caption, design: .monospaced)).lineLimit(1).truncationMode(.middle) }
        }
        .contextMenu(forSelectionType: MCPServer.ID.self) { ids in
            if let m = servers.first(where: { ids.contains($0.id) }) { removeButton(m) }
        }
        .searchable(text: $search, prompt: "Filter servers")
        .toolbar {
            Picker("Scope", selection: $scope) {
                Text("All scopes").tag(Scope?.none)
                ForEach(Scope.allCases, id: \.self) { Text($0.rawValue).tag(Optional($0)) }
            }
        }
        .bulkSelectable($sel, visible: visible, actions: [
            BulkAction(title: "Remove", icon: "trash", check: bulkCheck(picked) { cliScope($0) == nil ? "are defined by a plugin or managed settings (remove them there)" : nil }) {
                model.proposeBulk("Remove \(picked.count) MCP server\(picked.count == 1 ? "" : "s")", bulkPlan(picked, label: { "\($0.name) (\($0.scope.rawValue))" }) { m in
                    cliScope(m).map { .cli(args: ["mcp", "remove", m.name, "-s", $0], dryRun: nil, cwd: m.project) }
                })
            },
        ])
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

    @ViewBuilder private func removeButton(_ m: MCPServer) -> some View {
        let cliScope = cliScope(m)
        Button("Remove \(m.name)") {
            model.propose("Remove MCP server \(m.name)", .cli(args: ["mcp", "remove", m.name, "-s", cliScope!], dryRun: nil, cwd: m.project))
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
        let visible = rows.map(\.id)
        let picked = model.snapshot.components.filter { sel.contains($0.id) }
        Table(rows, selection: $sel.ids, sortOrder: $sort) {
            TableColumn("", value: \Row.name) { (r: Row) in SelectBox(sel: $sel, id: r.id, visible: visible, name: r.name) }.width(22)
            TableColumn("Name", value: \.name) { r in
                VStack(alignment: .leading) {
                    Text(r.name).fontWeight(.medium)
                    Text(r.c.description).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .explains(r.c.kind.term, "\(r.c.description)\n\nFrom: \(origin(r.c))")
            }
            TableColumn("Type") { Text($0.c.kind.rawValue) }.width(80)
            TableColumn("Scope") { r in
                ScopeMenu(current: ScopeMove.target(of: r.c), fixedLabel: r.c.scope == .plugin ? "Plugin" : r.c.scope.rawValue, allowLocal: false) { t in
                    model.moveScope(r.c.name, to: t) { try ScopeMove.move(component: r.c, to: t) }
                }
            }.width(min: 100, ideal: 110)
            TableColumn("Listed", value: \.tokens) { r in
                Text(r.c.override == "user-invocable-only" ? "hidden" : r.tokens == 0 ? "on demand" : formatTokens(r.tokens)).monospacedDigit()
                    .help(Term.skillListing.tooltip)
            }.width(80)
            TableColumn("Uses", value: \.uses) { Text("\($0.uses)").monospacedDigit() }.width(50)
            TableColumn("Last used", value: \.last) { Text(relative($0.c.lastUsed)) }.width(110)
            TableColumn("Lines", value: \.lines) { r in Text("\(r.lines)").monospacedDigit().foregroundStyle(r.lines > 500 ? PColor.attention.fg : .primary) }.width(50)
        }
        .contextMenu(forSelectionType: Component.ID.self) { ids in
            TrashButton(urls: model.snapshot.components.filter { ids.contains($0.id) }.map(trashURL))
        }
        .searchable(text: $search, prompt: "Filter by name or description")
        .toolbar {
            Picker("Kind", selection: $kind) {
                Text("All").tag(ComponentKind?.none)
                ForEach(ComponentKind.allCases.filter { $0 != .skill }, id: \.self) { Text($0.rawValue + "s").tag(Optional($0)) }
            }
            .pickerStyle(.segmented)
            if let c = selected { TrashButton(url: trashURL(c)) }
        }
        .bulkSelectable($sel, visible: visible, actions: [
            BulkAction(title: "Move to Trash", icon: "trash", check: bulkCheck(picked) { $0.ownsFile ? nil : "come from plugins or other agents" }) {
                model.proposeBulk("Move \(picked.count) item\(picked.count == 1 ? "" : "s") to the Trash", bulkPlan(picked, label: { "\($0.kind.rawValue): \($0.name)" }) { .trash([trashURL($0)]) })
            },
        ])
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
    /// A skill is its whole folder; agents and commands are single files.
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
        let visible = plugins.map(\.id)
        let picked = model.snapshot.plugins.filter { sel.contains($0.id) }
        let anyPicked = bulkCheck(picked) { _ in nil }
        Table(plugins, selection: $sel.ids, sortOrder: $sort) {
            TableColumn("", value: \Plugin.id) { (p: Plugin) in SelectBox(sel: $sel, id: p.id, visible: visible, name: p.id) }.width(22)
            TableColumn("Plugin", value: \.id) { p in
                HStack {
                    Image(systemName: p.enabled ? "checkmark.circle.fill" : "circle").foregroundStyle(p.enabled ? PColor.success.fg : .secondary)
                        .help(p.enabled ? "Enabled" : "Disabled: costs no context")
                    VStack(alignment: .leading) {
                        Text(p.id).fontWeight(.medium)
                        if !p.description.isEmpty { Text(p.description).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    }
                        .explains(.plugin, (p.description.isEmpty ? "" : p.description + "\n\n") + "From marketplace: \(p.marketplace)" + (p.repoURL.map { "\nSource: \($0.absoluteString)" } ?? ""))
                    if !p.notes.isEmpty { Image(systemName: "exclamationmark.bubble").foregroundStyle(PColor.attention.fg).help(p.notes.joined(separator: "\n")) }
                }
            }
            TableColumn("Scope", value: \.scope) { p in
                ScopeMenu(current: ScopeMove.target(ofPlugin: p), fixedLabel: p.scope.capitalized) { t in model.movePlugin(p, to: t) }
            }.width(min: 100, ideal: 110)
            TableColumn("Version", value: \.version) { p in
                if let v = p.latestVersion {
                    Label("\(p.version.prefix(12)) → \(v)", systemImage: "arrow.up.circle.fill").foregroundStyle(.blue).lineLimit(1)
                        .help("Update available: select it, then choose Update")
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
                ContentUnavailableView("No plugins installed", systemImage: "puzzlepiece.extension", description: Text("Find plugins worth adding in Discover."))
            }
        }
        .searchable(text: $search, prompt: "Filter plugins")
        .contextMenu(forSelectionType: Plugin.ID.self) { ids in
            let outdated = plugins.filter { ids.contains($0.id) && $0.latestVersion != nil }
            if outdated.count == 1, let p = outdated.first {
                Button("Update to \(p.latestVersion!)…") { model.propose("Update \(p.id)", p.cli("update")) }
            }
            TrashButton(urls: plugins.filter { ids.contains($0.id) }.map(\.installPath))
        }
        .bulkSelectable($sel, visible: visible, actions: [
            BulkAction(title: "Turn On", icon: "checkmark.circle", check: anyPicked, run: cli(picked, "enable") { $0.enabled ? "already enabled" : nil }),
            BulkAction(title: "Turn Off", icon: "circle", check: anyPicked, run: cli(picked, "disable") { $0.enabled ? nil : "already disabled" }),
            BulkAction(title: "Update…", icon: "arrow.up.circle", check: anyPicked, run: cli(picked, "update")),
            BulkAction(title: "Uninstall…", icon: "trash", check: anyPicked, run: cli(picked, "uninstall")),
        ])
        .toolbar {
            if sel.count == 1, let p = plugins.first(where: { sel.contains($0.id) }) { TrashButton(url: p.installPath) }
            if sel.count == 1, let p = plugins.first(where: { sel.contains($0.id) }) {
                Button(p.enabled ? "Turn Off" : "Turn On") {
                    model.propose("\(p.enabled ? "Disable" : "Enable") \(p.id)", p.cli(p.enabled ? "disable" : "enable"))
                }
                Button("Update…") { model.propose("Update \(p.id)", p.cli("update")) }
                Button("Uninstall…") { model.propose("Uninstall \(p.id)", p.cli("uninstall")) }
            }
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
        // Group by who added the hook: you (settings files) or a plugin.
        let groups = Dictionary(grouping: hooks, by: \.source).sorted { ($0.key.hasPrefix("Plugin") ? 1 : 0, $0.key) < ($1.key.hasPrefix("Plugin") ? 1 : 0, $1.key) }
        // One row per (source, command); its id is its first hook's.
        let rowsByID = Dictionary(uniqueKeysWithValues: groups.flatMap { _, items in Dictionary(grouping: items, by: \.command).values.map { ($0[0].id, $0) } })
        let visible = groups.flatMap { _, items in Dictionary(grouping: items, by: \.command).values.sorted { $0[0].command < $1[0].command }.map(\.[0].id) }
        let pickedRows = sel.ids.compactMap { rowsByID[$0] }
        List(selection: $sel.ids) {
            ForEach(groups, id: \.key) { source, items in
                Section(source.hasPrefix("Plugin · ") ? "From plugin \(source.dropFirst(9))" : "Added by you · \(source)") {
                    // One row per program: the same command on several events is one tool reporting several moments.
                    ForEach(Dictionary(grouping: items, by: \.command).values.sorted { $0[0].command < $1[0].command }, id: \.[0].id) { same in
                        row(same, visible)
                    }
                }
            }
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
            TrashButton(urls: Array(Set(picked.compactMap(\.scriptPath).filter(exists))), label: "Move Script to Trash")
        }
        .searchable(text: $search, prompt: "Filter hooks by command, event or source")
        .bulkSelectable($sel, visible: visible, actions: [
            BulkAction(title: "Remove", icon: "trash", check: bulkCheck(pickedRows) { $0[0].source.hasPrefix("Plugin") ? "come from plugins (turn the plugin off in Plugins)" : nil }) {
                model.proposeBulk("Remove \(pickedRows.count) hook\(pickedRows.count == 1 ? "" : "s")", bulkPlan(pickedRows, label: { ($0[0].scriptPath?.lastPathComponent ?? $0[0].command) + " · " + $0[0].source }) { same in
                    .removeHooks(same.map { HookRef(file: $0.sourceURL, event: $0.event, matcher: $0.matcher, command: $0.command) })
                })
            },
        ])
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

    private func row(_ same: [Hook], _ visibleRowIDs: [UUID]) -> some View {
        let h = same[0]
        let waits = same.filter { !$0.async }  // background hooks can't block or add context
        return HStack(alignment: .top) {
        SelectBox(sel: $sel, id: h.id, visible: visibleRowIDs, name: h.scriptPath?.lastPathComponent ?? h.command)
        VStack(alignment: .leading, spacing: 3) {
            Text(h.scriptPath?.lastPathComponent ?? h.command).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
            Text("Runs: " + same.map { when($0).lowercased() }.joined(separator: " · ")).font(.caption).lineLimit(2)
            if model.explaining.contains(model.explanationKey(h)) {
                HStack(spacing: 4) { ProgressView().controlSize(.mini); Text("Asking Claude…") }.font(.caption).foregroundStyle(.secondary)
            } else if let p = purpose(h) {
                Text(p).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }
            // Shown beside the hook's own description, never in place of it: a script can try to steer the model.
            if let guess = model.hookExplanations[model.explanationKey(h)] {
                Label("AI guess, not verified: \(guess)", systemImage: "sparkles").font(.caption).foregroundStyle(.secondary).lineLimit(3)
            } else if purpose(h) == nil, !model.explaining.contains(model.explanationKey(h)) {
                HStack(spacing: 6) {
                    Text("No description.").font(.caption).foregroundStyle(.secondary)
                    Button("Explain with Claude") { Task { await model.explain(h) } }.controlSize(.mini)
                        .help("Sends this hook's command and script to Claude (Haiku) for a one-sentence summary. Saved, so it runs once.")
                }
            }
            HStack(spacing: 6) {
                if let from = ScopeMove.target(ofSettings: h.sourceURL) {
                    ScopeMenu(current: from) { t in model.moveScope("\(h.event) hook", to: t) { try ScopeMove.move(hook: h, to: t) } }.controlSize(.small)
                }
                let reach = whereRuns(h)
                badge(reach.text, reach.everywhere ? "globe" : "folder", reach.everywhere ? .blue : .secondary)
                if same.allSatisfy(\.async) { badge("In the background", "moon", .secondary) }
                if waits.contains(where: { ["SessionStart", "UserPromptSubmit"].contains($0.event) }) {
                    badge("May add text to context", "text.bubble", PColor.attention.fg)
                        .help("This event lets a hook add its output to Claude's context. Whether this one does depends on what it prints.")
                }
                if waits.contains(where: { $0.event == "PreToolUse" }) {
                    badge("May block tools", "hand.raised", .purple)
                        .help("This event lets a hook stop a tool call. Whether this one does depends on what it returns.")
                }
                if let s = h.scriptPath, !exists(s) { badge("Broken: script missing", "xmark.octagon", PColor.danger.fg) }
            }
        }
        }
        .padding(.vertical, 2)
        .tag(h.id)
    }

    private func badge(_ text: String, _ icon: String, _ color: Color) -> some View {
        Label(text, systemImage: icon).font(.caption2).foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 1).background(color.opacity(0.12), in: Capsule())
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
