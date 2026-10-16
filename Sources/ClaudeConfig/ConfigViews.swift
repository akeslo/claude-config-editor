import ConfigCore
import SwiftUI

struct PermissionsView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: PermissionRule.ID?
    @State private var showProjectApprovals = false

    var body: some View {
        let rules = model.snapshot.permissions.filter { showProjectApprovals || $0.kind != "allowedTools" }
        Table(rules, selection: $selection) {
            TableColumn("Type") { r in
                Text(r.kind).foregroundStyle(r.kind == "deny" ? .red : r.kind == "ask" ? .orange : .primary)
                    .help(r.kind == "allowedTools" ? Term.allowedTools.tooltip : "\(r.kind): " + Term.permissions.tooltip)
            }.width(90)
            TableColumn("Rule") { Text($0.rule).font(.system(.body, design: .monospaced)).lineLimit(1).truncationMode(.middle) }
            TableColumn("Source") { r in Text(r.source).help(shortPath(r.sourceURL)) }.width(200)
        }
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

    var body: some View {
        let servers = model.snapshot.mcpServers
        Table(servers, selection: $selection) {
            TableColumn("Name") { Text($0.name).fontWeight(.medium) }
            TableColumn("Scope") { m in Text(m.scope.rawValue).help(Term.mcpScope.tooltip) }.width(110)
            TableColumn("Where") { m in Text(m.project.map { ($0 as NSString).lastPathComponent } ?? "everywhere").help(m.project ?? "") }.width(140)
            TableColumn("Type") { Text($0.transport) }.width(60)
            TableColumn("Command / URL") { Text($0.command).font(.system(.caption, design: .monospaced)).lineLimit(1).truncationMode(.middle) }
        }
        .contextMenu(forSelectionType: MCPServer.ID.self) { ids in
            if let m = servers.first(where: { ids.contains($0.id) }) { removeButton(m) }
        }
        .toolbar {
            if let m = servers.first(where: { $0.id == selection }) { removeButton(m) }
        }
        .onChange(of: selection) {
            guard let m = servers.first(where: { $0.id == selection }) else { return }
            model.info = InfoItem(m.name, term: .mcpServer, facts: [
                ("Scope", m.scope.rawValue), ("Project", m.project ?? "—"), ("Type", m.transport),
                ("Defined in", shortPath(m.source)),
                ("Env keys", m.env.keys.sorted().joined(separator: ", ").ifEmpty("none")),
            ], file: m.source, text: redacted(m.raw))
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
    @State private var selection: Component.ID?
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
                .help(r.c.description)
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
        .searchable(text: $search, prompt: "Filter by name or description")
        .toolbar {
            Picker("Kind", selection: $kind) {
                Text("All").tag(ComponentKind?.none)
                ForEach(ComponentKind.allCases, id: \.self) { Text($0.rawValue + "s").tag(Optional($0)) }
            }
            .pickerStyle(.segmented)
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
            model.info = InfoItem(c.name, term: c.kind == .skill ? .skill : c.kind == .subagent ? .subagent : c.kind == .command ? .command : .outputStyle, facts: [
                ("Scope", c.scope.rawValue), ("From", c.owner ?? "personal"),
                ("Always listed", c.listingTokens > 0 ? "Yes, \(formatTokens(c.listingTokens))" : "No"),
                ("Override", c.override ?? "none"), ("Uses", "\(c.usageCount)"), ("Last used", relative(c.lastUsed)),
                ("Lines", "\(c.lineCount)"), ("Frontmatter", c.frontmatterKeys.joined(separator: ", ")),
            ], file: c.file, text: c.description)
        }
    }

    private var selected: Component? { model.snapshot.components.first { $0.id == selection } }
}

struct PluginsView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: Plugin.ID?

    var body: some View {
        let plugins = model.snapshot.plugins
        Table(plugins, selection: $selection) {
            TableColumn("Plugin") { p in
                HStack {
                    Image(systemName: p.enabled ? "checkmark.circle.fill" : "circle").foregroundStyle(p.enabled ? .green : .secondary)
                        .help(p.enabled ? "Enabled" : "Disabled: costs no context")
                    Text(p.id).fontWeight(.medium)
                    if !p.notes.isEmpty { Image(systemName: "exclamationmark.bubble").foregroundStyle(.orange).help(p.notes.joined(separator: "\n")) }
                }
            }
            TableColumn("Version") { Text($0.version).lineLimit(1) }.width(90)
            TableColumn("Always-on") { p in
                Text(p.enabled ? model.pluginTokens[p.id].map(formatTokens) ?? "…" : "—").monospacedDigit()
                    .help("Context added to every session, from claude plugin details")
            }.width(90)
            TableColumn("Uses") { Text("\($0.usageCount)").monospacedDigit() }.width(50)
            TableColumn("Last used") { Text(relative($0.lastUsed)) }.width(110)
        }
        .toolbar {
            if let p = plugins.first(where: { $0.id == selection }) {
                Button(p.enabled ? "Disable…" : "Enable…") {
                    model.propose("\(p.enabled ? "Disable" : "Enable") \(p.id)", .cli(args: ["plugin", p.enabled ? "disable" : "enable", p.id], dryRun: nil, cwd: nil))
                }
                Button("Update…") { model.propose("Update \(p.id)", .cli(args: ["plugin", "update", p.id], dryRun: nil, cwd: nil)) }
                Button("Uninstall…") { model.propose("Uninstall \(p.id)", .cli(args: ["plugin", "uninstall", p.id], dryRun: nil, cwd: nil)) }
            }
        }
        .onChange(of: selection) {
            guard let p = plugins.first(where: { $0.id == selection }) else { return }
            let parts = model.snapshot.components.filter { $0.owner == p.id }
            model.info = InfoItem(p.id, term: .plugin, facts: [
                ("Enabled", p.enabled ? "Yes" : "No"), ("Version", p.version), ("Scope", p.scope), ("Marketplace", p.marketplace),
                ("Always-on", model.pluginTokens[p.id].map(formatTokens) ?? "—"), ("Uses", "\(p.usageCount)"),
            ], file: p.installPath, text: (parts.isEmpty ? "" : "Contains:\n" + parts.map { "\($0.kind.rawValue): \($0.name)" }.joined(separator: "\n")) + (p.notes.isEmpty ? "" : "\n\nNotes:\n" + p.notes.joined(separator: "\n")))
        }
    }
}

struct HooksView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: Hook.ID?

    var body: some View {
        let hooks = model.snapshot.hooks
        Table(hooks, selection: $selection) {
            TableColumn("Event") { h in Text(h.event).fontWeight(.medium).help(eventHelp(h.event)) }.width(140)
            TableColumn("Matcher") { h in
                Text(h.matcherIsValid ? (h.matcher ?? "all").ifEmpty("all") : "invalid").foregroundStyle(h.matcherIsValid ? .primary : Color.red)
            }.width(110)
            TableColumn("Command") { h in
                HStack {
                    if let s = h.scriptPath, !exists(s) { Image(systemName: "xmark.octagon").foregroundStyle(.red).help("Script not found: \(shortPath(s))") }
                    Text(h.command).font(.system(.caption, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                }
            }
            TableColumn("Runs") { h in Text(h.async ? "async" : h.timeout.map { "\($0)s timeout" } ?? "waits") }.width(90)
            TableColumn("Source") { Text($0.source).lineLimit(1) }.width(200)
        }
        .onChange(of: selection) {
            guard let h = hooks.first(where: { $0.id == selection }) else { return }
            model.info = InfoItem("\(h.event) hook", term: .hook, facts: [
                ("Event", h.event), ("Matcher", h.matcher ?? "all"), ("Source", h.source), ("Async", h.async ? "Yes" : "No"),
                ("Adds to context", ["SessionStart", "UserPromptSubmit"].contains(h.event) ? "Can (its output)" : "No"),
            ], file: h.sourceURL, text: h.command)
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

struct InstructionsView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: InstructionFile.ID?
    @State private var problemsOnly = false

    var body: some View {
        let files = model.snapshot.instructions.filter { !problemsOnly || !$0.problems.isEmpty }
        Table(files, selection: $selection) {
            TableColumn("File") { f in
                HStack {
                    if !f.problems.isEmpty { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help(f.problems.joined(separator: "\n")) }
                    Text(shortPath(f.url)).lineLimit(1).truncationMode(.head)
                }
            }
            TableColumn("Type") { f in Text(f.kind.rawValue).help(term(f).tooltip) }.width(110)
            TableColumn("Loads") { f in Text(f.pathScoped ? "with matching files" : f.project == nil ? "every session" : "in project").help(f.pathScoped ? "Has paths: frontmatter" : "") }.width(130)
            TableColumn("Lines") { f in Text("\(f.lines)").monospacedDigit().foregroundStyle(f.lines > 200 ? .orange : .primary) }.width(60)
            TableColumn("Context") { Text(formatTokens($0.tokens)).monospacedDigit() }.width(90)
        }
        .toolbar { Toggle("Only with problems", isOn: $problemsOnly) }
        .onChange(of: selection) {
            guard let f = files.first(where: { $0.id == selection }) else { return }
            model.info = InfoItem(f.url.lastPathComponent, term: term(f), facts: [
                ("Path", shortPath(f.url)), ("Project", f.project.map { shortPath(URL(filePath: $0)) } ?? "all"),
                ("Lines", "\(f.lines)"), ("Context", formatTokens(f.tokens)),
            ], file: f.url, text: f.problems.isEmpty ? nil : f.problems.joined(separator: "\n"))
        }
    }

    private func term(_ f: InstructionFile) -> Term {
        switch f.kind {
        case .claudeMD: .claudeMD
        case .localMD: .claudeLocalMD
        case .rule: .rules
        case .memoryIndex: .autoMemory
        }
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: String?
    @State private var doctor: String?

    struct Row: Identifiable {
        var id: String { source.id + "|" + key }
        let source: SettingsSource
        let key: String
        let value: String
    }

    var body: some View {
        let rows = model.snapshot.settings.flatMap { s in
            s.root.keys.sorted().map { Row(source: s, key: $0, value: compact(s.root[$0])) }
        } + keybindingRows
        Table(rows, selection: $selection) {
            TableColumn("Key") { r in
                HStack {
                    if r.source.scope == .managed { Image(systemName: "lock.fill").help(Term.managedSettings.tooltip) }
                    Text(r.key).fontWeight(.medium).help(term(r.key).tooltip)
                }
            }.width(200)
            TableColumn("Value") { Text($0.value).font(.system(.caption, design: .monospaced)).lineLimit(1).truncationMode(.tail) }
            TableColumn("Scope") { r in Text(r.source.scope.rawValue).help(Term.precedence.tooltip) }.width(110)
            TableColumn("File") { r in Text(shortPath(r.source.url)).lineLimit(1).truncationMode(.head) }.width(220)
        }
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

    var body: some View {
        let list = model.available
            .filter { !hideInstalled || !$0.installed }
            .filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.description.localizedCaseInsensitiveContains(search) }
        Group {
            if model.available.isEmpty {
                ProgressView("Loading marketplaces…")
            } else {
                Table(list, selection: $selection) {
                    TableColumn("Plugin") { p in
                        VStack(alignment: .leading) {
                            Text(p.name).fontWeight(.medium)
                            Text(p.description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        .help(p.description)
                    }
                    TableColumn("Marketplace") { p in Text(p.marketplace).help(Term.marketplace.tooltip) }.width(170)
                    TableColumn("Installs") { Text($0.installCount.formatted()).monospacedDigit() }.width(80)
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
            model.info = InfoItem(p.name, term: .marketplace, facts: [("ID", p.id), ("Marketplace", p.marketplace), ("Installs", p.installCount.formatted())], text: p.description)
        }
    }
}
