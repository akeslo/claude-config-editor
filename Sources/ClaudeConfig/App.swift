import ConfigCore
import SwiftUI

@main
struct ClaudeConfigApp: App {
    @State private var model = AppModel()
    // Not @AppStorage or a closure Binding: either re-pushes the status item image on unrelated updates, and
    // during window layout that crashes AppKit (_postWindowNeedsUpdateConstraints) on Agents & Commands.
    // AppSettingsView persists it.
    @State private var showMenuBar = UserDefaults.standard.bool(forKey: "minimizeToMenuBar") || (UserDefaults.standard.object(forKey: "showSkillsMenuBar") as? Bool ?? true)

    var body: some Scene {
        WindowGroup("Claude Config", id: "main") {
            RootView()
                .environment(model)
                .tint(.brand)
                .frame(minWidth: 980, minHeight: 600)
                .task {
                    applyDockPolicy()
                    // `-appearance light|dark` on the command line forces a mode (used for screenshots of both).
                    if let a = UserDefaults.standard.string(forKey: "appearance") { NSApp.appearance = NSAppearance(named: a == "light" ? .aqua : .darkAqua) }
                    await model.refresh()
                }
                .task { await model.loadAdvice() }
        }
        .defaultSize(width: 1440, height: 900)
        .commands {
            CommandGroup(after: .toolbar) {
                Button("Rescan") { Task { await model.rescan() } }.keyboardShortcut("r")
                Button("Toggle Explanations") { model.showInspector.toggle() }.keyboardShortcut("i", modifiers: [.command, .option])
            }
        }
        Settings { AppSettingsView(showMenuBar: $showMenuBar) }
        MenuBarExtra("Skills", systemImage: "wand.and.stars", isInserted: $showMenuBar) {
            MenuBarSkills().environment(model).tint(.brand)
        }
        .menuBarExtraStyle(.window)
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(selection: $model.screen) {
                ForEach(Screen.sidebar(for: model.detected), id: \.title) { g in
                    Section(g.title) { ForEach(g.screens, id: \.self) { sidebarRow($0) } }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220)
        } detail: {
            Group {
                if search.isEmpty {
                    VStack(spacing: 0) {
                        if model.snapshot.cliAvailable { AskClaudeBar(section: model.section).id(model.screen) }
                        detail
                    }
                } else { SearchResultsView(query: search) { search = "" } }
            }
                .appListStyle()
                .navigationTitle(search.isEmpty ? title(model.screen) : "Search")
                .toolbar {
                    ToolbarItemGroup {
                        let issues = model.isClaudeScreen ? model.issues.filter { model.section == .health || $0.section == model.section } : []
                        if !issues.isEmpty {
                            Button { copy(Issue.aiPrompt(for: issues)) } label: { Label("Copy AI Prompt", systemImage: "doc.on.clipboard") }
                                .help(promptHelp(Issue.aiPrompt(for: issues)))
                        }
                        Button { copy("# Claude Config · \(title(model.screen))\n\n" + model.screenInfo(model.section)) } label: { Label("Copy info", systemImage: "doc.text") }
                            .help("Copy a Markdown summary of this screen (rows, sources, warnings; secrets masked) to paste into another chat")
                        if model.loading || model.measuringStorage { ProgressView().controlSize(.small).help("Scanning…") }
                        Button { Task { await model.rescan() } } label: { Label("Rescan", systemImage: "arrow.clockwise") }
                            .help("Read all config files again (⌘R)")
                        Button { model.showInspector.toggle() } label: { Label("Explanations", systemImage: "sidebar.right") }
                            .help("Show or hide the explanation panel (⌥⌘I)")
                    }
                }
                .inspector(isPresented: $model.showInspector) {
                    InfoPanel(item: model.info ?? InfoItem(model.section.rawValue, term: model.section.term))
                        .inspectorColumnWidth(min: 260, ideal: 320, max: 420)
                }
        }
        .searchable(text: $search, placement: .sidebar, prompt: "Search everything")
        .onChange(of: model.screen) { model.info = nil }
        .sheet(item: $model.pendingFix) { FixSheet(pending: $0) }
        .overlay(alignment: .bottom) { UndoToast() }
    }

    @ViewBuilder private var detail: some View {
        switch model.screen {
        case .overview: ReviewView()
        case .library(.catalogue): CatalogueView()
        case .library(.backups): BackupsView()
        case .library(.disk): VSplitView { StorageView(); ProjectsView() }
        case .kind(let id, let kind):
            if id != .claude, let p = model.detected.first(where: { $0.0.id == id })?.0 {
                ProviderKindView(provider: p, kind: kind).id(model.screen)
            } else {
                switch model.section {
                case .skills: SkillsView()
                case .permissions: PermissionsView()
                case .mcp: MCPView()
                case .agents: ComponentsView()
                case .plugins: PluginsView()
                case .hooks: HooksView()
                case .instructions: AgentFilesView()
                default: SettingsView()
                }
            }
        }
    }

    private func title(_ s: Screen) -> String {
        guard let id = s.provider, id != .claude, let p = model.detected.first(where: { $0.0.id == id })?.0 else { return s.title }
        return "\(p.displayName) · \(s.title)"
    }

    private func sidebarRow(_ s: Screen) -> some View {
        Label(s.title, systemImage: s.symbol)
            .badge(badge(for: s))
            .help(s.section.term.tooltip)
            .tag(s)
    }

    private func badge(for s: Screen) -> Int {
        if s == .overview { return model.issues.filter { $0.severity >= .warning }.count }
        // Issues come from the Claude scan; Commands shares Agents' section, so only Agents carries the badge.
        guard s.provider == .claude, s != .kind(.claude, .commands) else { return 0 }
        return model.issues.filter { $0.section == s.section && $0.severity >= .warning }.count
    }
}

/// The right-hand panel: what the selected thing is and how it fits into Claude Code.
struct InfoPanel: View {
    let item: InfoItem

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.m) {
                Text(item.title).font(.title3.weight(.semibold)).textSelection(.enabled)
                if item.title != item.term.title {
                    Text(item.term.title).font(.subheadline).foregroundStyle(.secondary)
                }
                if !item.facts.isEmpty {
                    Grid(alignment: .leading, horizontalSpacing: Space.m, verticalSpacing: Space.s) {
                        ForEach(item.facts) { f in
                            GridRow {
                                Text(f.label).foregroundStyle(.secondary)
                                Text(f.value).textSelection(.enabled)
                            }
                        }
                    }
                    .font(.callout)
                }
                if let file = item.file {
                    HStack {
                        Button("Reveal in Finder") { reveal(file) }
                        if !file.hasDirectoryPath { Button("Open") { openFile(file) } }
                        TrashButton(url: file)
                    }
                    .controlSize(.small)
                }
                Divider()
                Text("How it fits into Claude Code").font(.cardTitle)
                Text(item.term.detail).fixedSize(horizontal: false, vertical: true)
                Link("Read the docs", destination: item.term.docURL)
                if let link = item.link { Link("View Source", destination: link).help(link.absoluteString) }
                if let prompt = item.prompt {
                    Button("Copy AI Prompt", systemImage: "doc.on.clipboard") { copy(prompt) }
                        .help(promptHelp(prompt))
                }
                if let text = item.text {
                    Divider()
                    Text(text).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                }
            }
            .padding(Space.l)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// One search across every page: issues, skills, agents, MCP servers, hooks, plugins and permission rules.
struct SearchResultsView: View {
    @Environment(AppModel.self) private var model
    let query: String
    let done: () -> Void

    private struct Hit: Identifiable {
        let id = UUID()
        let section: AppSection
        let title: String
        let detail: String
    }

    private var hits: [Hit] {
        let s = model.snapshot
        var all: [Hit] = model.issues.map { Hit(section: $0.section, title: $0.title, detail: $0.subject) }
        all += s.components.map { Hit(section: $0.kind == .skill ? .skills : .agents, title: $0.name, detail: $0.description) }
        all += s.mcpServers.map { Hit(section: .mcp, title: $0.name, detail: $0.command) }
        all += s.hooks.map { Hit(section: .hooks, title: $0.event, detail: $0.command) }
        all += s.plugins.map { Hit(section: .plugins, title: $0.id, detail: $0.description) }
        all += s.permissions.map { Hit(section: .permissions, title: $0.rule, detail: "\($0.kind) · \($0.source)") }
        all += AppSection.allCases.map { Hit(section: $0, title: $0.rawValue, detail: $0.group) }
        return all.filter { $0.title.localizedCaseInsensitiveContains(query) || $0.detail.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        let hits = hits
        if hits.isEmpty {
            ContentUnavailableView.search(text: query)
        } else {
            List {
                ForEach(AppSection.allCases) { sec in
                    let group = hits.filter { $0.section == sec }
                    if !group.isEmpty {
                        SwiftUI.Section(sec.rawValue) {
                            ForEach(group) { h in
                                Button { model.section = sec; done() } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(h.title).lineLimit(1)
                                        if !h.detail.isEmpty { Text(h.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .help("Open \(sec.rawValue)")
                            }
                        }
                    }
                }
            }
        }
    }
}

/// Library › Skills catalogue: the Community list with its own filter box.
struct CatalogueView: View {
    @State private var search = ""
    var body: some View {
        VStack(spacing: 0) {
            TextField("Filter skills", text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 260).padding(Space.m)
                .frame(maxWidth: .infinity, alignment: .leading)
            CommunityView(search: search)
        }
    }
}
