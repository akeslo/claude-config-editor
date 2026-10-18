import ConfigCore
import SwiftUI

struct PermissionsView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: PermissionRule.ID?
    @State private var showProjectApprovals = false
    @State private var search = ""
    @State private var sort = [KeyPathComparator(\PermissionRule.kind)]

    var body: some View {
        let rules = model.snapshot.permissions.filter { showProjectApprovals || $0.kind != "allowedTools" }
            .filter { search.isEmpty || $0.rule.localizedCaseInsensitiveContains(search) || $0.source.localizedCaseInsensitiveContains(search) || $0.kind.localizedCaseInsensitiveContains(search) }
            .sorted(using: sort)
        Table(rules, selection: $selection, sortOrder: $sort) {
            TableColumn("Type", value: \.kind) { r in
                Text(r.kind).foregroundStyle(r.kind == "deny" ? .red : r.kind == "ask" ? .orange : .primary)
                    .help(r.kind == "allowedTools" ? Term.allowedTools.tooltip : "\(r.kind): " + Term.permissions.tooltip)
            }.width(90)
            TableColumn("Rule", value: \.rule) { Text($0.rule).font(.system(.body, design: .monospaced)).lineLimit(1).truncationMode(.middle) }
            TableColumn("Source", value: \.source) { r in Text(r.source).help(shortPath(r.sourceURL)) }.width(200)
        }
        .searchable(text: $search, prompt: "Filter rules")
        .toolbar {
            Toggle("Per-project approvals", isOn: $showProjectApprovals).help(Term.allowedTools.tooltip)
        }
        .onChange(of: selection) {
            guard let r = rules.first(where: { $0.id == selection }) else { return }
            model.info = InfoItem(r.rule, term: r.kind == "allowedTools" ? .allowedTools : .permissions,
                                  facts: [("Type", r.kind), ("Source", r.source), ("File", shortPath(r.sourceURL))], file: r.sourceURL)
        }
    }
}

struct MCPView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: MCPServer.ID?
    @State private var search = ""
    @State private var scope: Scope?
    @State private var sort = [KeyPathComparator(\MCPServer.name)]

    var body: some View {
        let servers = model.snapshot.mcpServers
            .filter { scope == nil || $0.scope == scope }
            .filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.description.localizedCaseInsensitiveContains(search) || $0.command.localizedCaseInsensitiveContains(search) }
            .sorted(using: sort)
        Table(servers, selection: $selection, sortOrder: $sort) {
            TableColumn("Name", value: \.name) { m in
                VStack(alignment: .leading) {
                    Text(m.name).fontWeight(.medium)
                    if !m.description.isEmpty { Text(m.description).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
                .explains(.mcpServer, "\(m.description.isEmpty ? "" : m.description + "\n\n")Runs: \(m.command) (\(m.transport))\nFrom: \(m.scope.rawValue)")
            }
            TableColumn("Scope", value: \.scope.rawValue) { m in Text(m.scope.rawValue).help(Term.mcpScope.tooltip) }.width(110)
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
            if let m = servers.first(where: { $0.id == selection }) { removeButton(m) }
        }
        .onChange(of: selection) {
            guard let m = servers.first(where: { $0.id == selection }) else { return }
            model.info = InfoItem(m.name, term: .mcpServer, facts: [
                ("Scope", m.scope.rawValue), ("Project", m.project ?? "—"), ("Type", m.transport),
                ("Defined in", shortPath(m.source)),
                ("Env keys", m.env.keys.sorted().joined(separator: ", ").ifEmpty("none")),
            ], file: m.source, text: (m.description.isEmpty ? "" : m.description + "\n\n") + redacted(m.raw))
        }
    }

    @ViewBuilder private func removeButton(_ m: MCPServer) -> some View {
        let cliScope: String? = switch m.scope {
        case .user: "user"
        case .local: "local"
        case .project: "project"
        default: nil
        }
        Button("Remove \(m.name)…") {
            model.propose("Remove MCP server \(m.name)", .cli(args: ["mcp", "remove", m.name, "-s", cliScope!], dryRun: nil, cwd: m.project))
        }
        .disabled(cliScope == nil)
        .help(cliScope == nil ? "Defined by \(m.scope.rawValue); remove it there." : "Runs claude mcp remove in the right scope.")
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
    @State private var selection = Set<Component.ID>()
    @State private var kind: ComponentKind? = .skill
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
        let rows = model.snapshot.components
            .filter { kind == nil || $0.kind == kind }
            .filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.description.localizedCaseInsensitiveContains(search) }
            .map(Row.init).sorted(using: sort)
        Table(rows, selection: $selection, sortOrder: $sort) {
            TableColumn("Name", value: \.name) { r in
                VStack(alignment: .leading) {
                    Text(r.name).fontWeight(.medium)
                    Text(r.c.description).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .explains(r.c.kind.term, "\(r.c.description)\n\nFrom: \(r.c.owner ?? r.c.scope.rawValue)")
            }
            TableColumn("Type") { Text($0.c.kind.rawValue) }.width(80)
            TableColumn("Scope") { r in Text(r.c.scope.rawValue).help(r.c.owner ?? "") }.width(70)
            TableColumn("Listed", value: \.tokens) { r in
                Text(r.c.override == "user-invocable-only" ? "hidden" : r.tokens == 0 ? "on demand" : formatTokens(r.tokens)).monospacedDigit()
                    .help(Term.skillListing.tooltip)
            }.width(80)
            TableColumn("Uses", value: \.uses) { Text("\($0.uses)").monospacedDigit() }.width(50)
            TableColumn("Last used", value: \.last) { Text(relative($0.c.lastUsed)) }.width(110)
            TableColumn("Lines", value: \.lines) { r in Text("\(r.lines)").monospacedDigit().foregroundStyle(r.lines > 500 ? .orange : .primary) }.width(50)
        }
        .contextMenu(forSelectionType: Component.ID.self) { ids in
            TrashButton(urls: model.snapshot.components.filter { ids.contains($0.id) }.map(trashURL))
        }
        .searchable(text: $search, prompt: "Filter by name or description")
        .toolbar {
            Picker("Kind", selection: $kind) {
                Text("All").tag(ComponentKind?.none)
                ForEach(ComponentKind.allCases, id: \.self) { Text($0.rawValue + "s").tag(Optional($0)) }
            }
            .pickerStyle(.segmented)
            if let c = selected { TrashButton(url: trashURL(c)) }
            if let c = selected, c.kind == .skill {
                if c.override == nil {
                    Button("Hide from listing…") {
                        model.propose("Hide \(c.name) from the skill listing", .settingsKey(file: Paths.userSettings, path: ["skillOverrides", c.name], value: "user-invocable-only"))
                    }.help("Sets skillOverrides to user-invocable-only: /\(c.name) still works, but its description stops costing context.")
                } else {
                    Button("Show in listing…") {
                        model.propose("Show \(c.name) in the skill listing", .settingsKey(file: Paths.userSettings, path: ["skillOverrides", c.name], value: nil))
                    }
                }
            }
        }
        .onChange(of: selection) {
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

    private var selected: Component? { model.snapshot.components.first { selection.contains($0.id) } }
    /// A skill is its whole folder; agents and commands are single files.
}

/// A skill is its whole folder; other components are one file.
func trashURL(_ c: Component) -> URL { c.kind == .skill && c.file.lastPathComponent == "SKILL.md" ? c.file.deletingLastPathComponent() : c.file }

struct PluginsView: View {
    @Environment(AppModel.self) private var model
    @State private var selection = Set<Plugin.ID>()
    @State private var search = ""
    @State private var sort = [KeyPathComparator(\Plugin.id)]

    var body: some View {
        let plugins = model.snapshot.plugins
            .filter { search.isEmpty || $0.id.localizedCaseInsensitiveContains(search) || $0.description.localizedCaseInsensitiveContains(search) }
            .sorted(using: sort)
        Table(plugins, selection: $selection, sortOrder: $sort) {
            TableColumn("Plugin", value: \.id) { p in
                HStack {
                    Image(systemName: p.enabled ? "checkmark.circle.fill" : "circle").foregroundStyle(p.enabled ? .green : .secondary)
                        .help(p.enabled ? "Enabled" : "Disabled: costs no context")
                    VStack(alignment: .leading) {
                        Text(p.id).fontWeight(.medium)
                        if !p.description.isEmpty { Text(p.description).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    }
                        .explains(.plugin, (p.description.isEmpty ? "" : p.description + "\n\n") + "From marketplace: \(p.marketplace)" + (p.repoURL.map { "\nSource: \($0.absoluteString)" } ?? ""))
                    if !p.notes.isEmpty { Image(systemName: "exclamationmark.bubble").foregroundStyle(.orange).help(p.notes.joined(separator: "\n")) }
                }
            }
            TableColumn("Version", value: \.version) { p in
                if let v = p.latestVersion {
                    Label("\(p.version.prefix(12)) → \(v)", systemImage: "arrow.up.circle.fill").foregroundStyle(.blue).lineLimit(1)
                        .help("Update available: select it and press Update…")
                } else { Text(p.version).lineLimit(1) }
            }.width(150)
            TableColumn("Always-on") { p in
                Text(p.enabled ? model.pluginTokens[p.id].map(formatTokens) ?? "…" : "—").monospacedDigit()
                    .help("Context added to every session, from claude plugin details")
            }.width(90)
            TableColumn("Uses", value: \.usageCount) { Text("\($0.usageCount)").monospacedDigit() }.width(50)
            TableColumn("Last used", value: \.lastUsed, comparator: OptionalDateComparator()) { Text(relative($0.lastUsed)) }.width(110)
        }
        .searchable(text: $search, prompt: "Filter plugins")
        .contextMenu(forSelectionType: Plugin.ID.self) { ids in
            let outdated = plugins.filter { ids.contains($0.id) && $0.latestVersion != nil }
            if outdated.count == 1, let p = outdated.first {
                Button("Update to \(p.latestVersion!)…") { model.propose("Update \(p.id)", .cli(args: ["plugin", "update", p.id], dryRun: nil, cwd: nil)) }
            }
            TrashButton(urls: plugins.filter { ids.contains($0.id) }.map(\.installPath))
        }
        .toolbar {
            if let p = plugins.first(where: { selection.contains($0.id) }) { TrashButton(url: p.installPath) }
            if let p = plugins.first(where: { selection.contains($0.id) }) {
                Button(p.enabled ? "Disable…" : "Enable…") {
                    model.propose("\(p.enabled ? "Disable" : "Enable") \(p.id)", .cli(args: ["plugin", p.enabled ? "disable" : "enable", p.id], dryRun: nil, cwd: nil))
                }
                Button("Update…") { model.propose("Update \(p.id)", .cli(args: ["plugin", "update", p.id], dryRun: nil, cwd: nil)) }
                Button("Uninstall…") { model.propose("Uninstall \(p.id)", .cli(args: ["plugin", "uninstall", p.id], dryRun: nil, cwd: nil)) }
            }
        }
        .onChange(of: selection) {
            guard let p = plugins.first(where: { selection.contains($0.id) }) else { return }
            let parts = model.snapshot.components.filter { $0.owner == p.id }
            model.info = InfoItem(p.id, term: .plugin, facts: [
                ("Enabled", p.enabled ? "Yes" : "No"), ("Version", p.version), ("Scope", p.scope), ("Marketplace", p.marketplace),
                ("Always-on", model.pluginTokens[p.id].map(formatTokens) ?? "—"), ("Uses", "\(p.usageCount)"),
            ], file: p.installPath, link: p.repoURL, text: (p.description.isEmpty ? "" : p.description + "\n\n") + (parts.isEmpty ? "" : "Contains:\n" + parts.map { "\($0.kind.rawValue): \($0.name)" }.joined(separator: "\n")) + (p.notes.isEmpty ? "" : "\n\nNotes:\n" + p.notes.joined(separator: "\n")))
        }
    }
}

struct HooksView: View {
    @Environment(AppModel.self) private var model
    @State private var selection = Set<Hook.ID>()
    @State private var search = ""

    var body: some View {
        let hooks = model.snapshot.hooks
            .filter { search.isEmpty || $0.command.localizedCaseInsensitiveContains(search) || $0.event.localizedCaseInsensitiveContains(search) || $0.source.localizedCaseInsensitiveContains(search) || ($0.matcher ?? "").localizedCaseInsensitiveContains(search) }
        // Group by who added the hook: you (settings files) or a plugin.
        let groups = Dictionary(grouping: hooks, by: \.source).sorted { ($0.key.hasPrefix("Plugin") ? 1 : 0, $0.key) < ($1.key.hasPrefix("Plugin") ? 1 : 0, $1.key) }
        List(selection: $selection) {
            ForEach(groups, id: \.key) { source, items in
                Section(source.hasPrefix("Plugin · ") ? "From plugin \(source.dropFirst(9))" : "Added by you · \(source)") {
                    // One row per program: the same command on several events is one tool reporting several moments.
                    ForEach(Dictionary(grouping: items, by: \.command).values.sorted { $0[0].command < $1[0].command }, id: \.[0].id) { same in
                        row(same)
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
                Button(rowCommands.count == 1 ? "Remove Hook…" : "Remove \(rowCommands.count) Hooks…") {
                    model.propose("Remove \(removable.count) hook entr\(removable.count == 1 ? "y" : "ies")", .removeHooks(removable.map { HookRef(file: $0.sourceURL, event: $0.event, command: $0.command) }))
                }
            }
            TrashButton(urls: Array(Set(picked.compactMap(\.scriptPath).filter(exists))), label: "Move Script to Trash…")
        }
        .searchable(text: $search, prompt: "Filter hooks by command, event or source")
        .onChange(of: selection) {
            guard let h = hooks.first(where: { selection.contains($0.id) }) else { return }
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

    private func row(_ same: [Hook]) -> some View {
        let h = same[0]
        let waits = same.filter { !$0.async }  // background hooks can't block or add context
        return VStack(alignment: .leading, spacing: 3) {
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
                let reach = whereRuns(h)
                badge(reach.text, reach.everywhere ? "globe" : "folder", reach.everywhere ? .blue : .secondary)
                if same.allSatisfy(\.async) { badge("In the background", "moon", .secondary) }
                if waits.contains(where: { ["SessionStart", "UserPromptSubmit"].contains($0.event) }) {
                    badge("May add text to context", "text.bubble", .orange)
                        .help("This event lets a hook add its output to Claude's context. Whether this one does depends on what it prints.")
                }
                if waits.contains(where: { $0.event == "PreToolUse" }) {
                    badge("May block tools", "hand.raised", .purple)
                        .help("This event lets a hook stop a tool call. Whether this one does depends on what it returns.")
                }
                if let s = h.scriptPath, !exists(s) { badge("Broken: script missing", "xmark.octagon", .red) }
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

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: String?
    @State private var doctor: String?
    @State private var search = ""
    @State private var sort = [KeyPathComparator(\Row.key)]

    struct Row: Identifiable {
        var id: String { source.id + "|" + key }
        let source: SettingsSource
        let key: String
        let value: String
        var scope: String { source.scope.rawValue }
        var file: String { shortPath(source.url) }
    }

    var body: some View {
        let rows = model.snapshot.settings.flatMap { s in
            s.root.keys.sorted().map { Row(source: s, key: $0, value: compact(s.root[$0])) }
        } + keybindingRows
        let shown = rows.filter { search.isEmpty || $0.key.localizedCaseInsensitiveContains(search) || $0.value.localizedCaseInsensitiveContains(search) }
            .sorted(using: sort)
        Table(shown, selection: $selection, sortOrder: $sort) {
            TableColumn("Key", value: \.key) { r in
                HStack {
                    if r.source.scope == .managed { Image(systemName: "lock.fill").help(Term.managedSettings.tooltip) }
                    Text(r.key).fontWeight(.medium).help(term(r.key).tooltip)
                }
            }.width(200)
            TableColumn("Value", value: \.value) { Text($0.value).font(.system(.caption, design: .monospaced)).lineLimit(1).truncationMode(.tail) }
            TableColumn("Scope", value: \.scope) { r in Text(r.scope).help(Term.precedence.tooltip) }.width(110)
            TableColumn("File", value: \.file) { r in Text(r.file).lineLimit(1).truncationMode(.head) }.width(220)
        }
        .searchable(text: $search, prompt: "Filter by key or value")
        .toolbar {
            Button("Run claude doctor") { Task { doctor = await ClaudeCLI.run(["doctor"]).output } }
                .help("Claude's own read-only diagnostics, including invalid settings files.")
        }
        .sheet(isPresented: Binding(get: { doctor != nil }, set: { if !$0 { doctor = nil } })) {
            VStack(alignment: .leading) {
                Text("claude doctor").font(.headline)
                ScrollView { Text(doctor ?? "").font(.system(.callout, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                HStack { Spacer(); Button("Close") { doctor = nil }.keyboardShortcut(.defaultAction) }
            }
            .padding().frame(width: 640, height: 420)
        }
        .onChange(of: selection) {
            guard let r = rows.first(where: { $0.id == selection }) else { return }
            model.info = InfoItem(r.key, term: term(r.key), facts: [("Scope", r.source.scope.rawValue), ("File", shortPath(r.source.url))],
                                  file: r.source.url, text: pretty(r.source.root[r.key]))
        }
    }

    /// keybindings.json is not a settings file but belongs on this screen.
    private var keybindingRows: [Row] {
        guard let kb = readJSON(Paths.keybindings) else { return [] }
        let source = SettingsSource(scope: .user, url: Paths.keybindings, project: nil, root: kb, modified: modificationDate(Paths.keybindings))
        return kb.keys.sorted().map { Row(source: source, key: $0, value: compact(kb[$0])) }
    }

    private func term(_ key: String) -> Term {
        switch key {
        case "hooks": .hook
        case "permissions": .permissions
        case "enabledPlugins", "extraKnownMarketplaces", "pluginConfigs": .plugin
        case "skillOverrides": .skillListing
        case "cleanupPeriodDays": .cleanupPeriod
        case "env": .env
        case "statusLine": .statusLine
        case "theme": .theme
        case "mcpServers", "enableAllProjectMcpServers", "enabledMcpjsonServers": .mcpServer
        default: .settings
        }
    }

    private func compact(_ v: Any?) -> String {
        guard let v else { return "" }
        if let d = v as? JSON { return "{ \(d.count) keys }" }
        if let a = v as? [Any] { return "[ \(a.count) items ]" }
        return "\(v)"
    }

    private func pretty(_ v: Any?) -> String? {
        guard let v, JSONSerialization.isValidJSONObject(v),
              let d = try? JSONSerialization.data(withJSONObject: v, options: [.prettyPrinted, .sortedKeys]) else { return v.map { "\($0)" } }
        return String(decoding: d, as: UTF8.self)
    }
}

struct DiscoverView: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""
    @State private var hideInstalled = true
    @State private var selection: AvailablePlugin.ID?
    @State private var sort = [KeyPathComparator(\AvailablePlugin.installCount, order: .reverse)]

    var body: some View {
        let list = model.available
            .filter { !hideInstalled || !$0.installed }
            .filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.description.localizedCaseInsensitiveContains(search) }
            .sorted(using: sort)
        Group {
            if model.available.isEmpty {
                ProgressView("Loading marketplaces…")
            } else {
                Table(list, selection: $selection, sortOrder: $sort) {
                    TableColumn("Plugin", value: \.name) { p in
                        VStack(alignment: .leading) {
                            Text(p.name).fontWeight(.medium)
                            Text(p.description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        .explains(.plugin, p.description)
                    }
                    TableColumn("Marketplace", value: \.marketplace) { p in Text(p.marketplace).help(Term.marketplace.tooltip) }.width(170)
                    TableColumn("Installs", value: \.installCount) { Text($0.installCount.formatted()).monospacedDigit() }.width(80)
                    TableColumn("") { p in Text(p.installed ? "Installed" : "").foregroundStyle(.secondary) }.width(70)
                }
            }
        }
        .searchable(text: $search, prompt: "Search plugins and skills")
        .toolbar {
            Toggle("Hide installed", isOn: $hideInstalled)
            if let p = list.first(where: { $0.id == selection }), !p.installed {
                Button("Install…") { model.propose("Install \(p.id)", .cli(args: ["plugin", "install", p.id], dryRun: nil, cwd: nil)) }
                    .help("Runs claude plugin install. Only install plugins you trust: they can run code on your machine.")
            }
        }
        .task { await model.loadAvailable() }
        .onChange(of: selection) {
            guard let p = list.first(where: { $0.id == selection }) else { return }
            model.info = InfoItem(p.name, term: .marketplace, facts: [("ID", p.id), ("Marketplace", p.marketplace), ("Installs", p.installCount.formatted())], link: p.repoURL, text: p.description)
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
