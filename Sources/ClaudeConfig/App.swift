import ConfigCore
import SwiftUI

@main
struct ClaudeConfigApp: App {
    @State private var model = AppModel()
    // Not @AppStorage: it re-pushes the status item on every defaults write, and writes made during
    // window layout then crash AppKit (_postWindowNeedsUpdateConstraints) on Agents & Commands.
    @State private var showMenuBar = UserDefaults.standard.object(forKey: "showSkillsMenuBar") as? Bool ?? true
    private var menuBarShown: Binding<Bool> {
        Binding(get: { showMenuBar }, set: { showMenuBar = $0; UserDefaults.standard.set($0, forKey: "showSkillsMenuBar") })
    }

    var body: some Scene {
        WindowGroup("Claude Config") {
            RootView()
                .environment(model)
                .tint(.brand)
                .frame(minWidth: 980, minHeight: 600)
                .task {
                    await model.refresh()
                    if UserDefaults.standard.object(forKey: "analyzeOnLaunch") as? Bool ?? true { await model.analyzeSkillsIfNeeded() }
                }
                .task { await model.checkForAppUpdate() }
                .task { await model.loadAdvice() }
        }
        .defaultSize(width: 1440, height: 900)
        .commands {
            CommandGroup(after: .toolbar) {
                Button("Rescan") { Task { await model.rescan() } }.keyboardShortcut("r")
                Button("Toggle Explanations") { model.showInspector.toggle() }.keyboardShortcut("i", modifiers: [.command, .option])
            }
        }
        Settings { AppSettingsView(showMenuBar: menuBarShown) }
        MenuBarExtra("Skills", systemImage: "wand.and.stars", isInserted: menuBarShown) {
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
            List(selection: $model.section) {
                ForEach(AppSection.groups, id: \.self) { g in
                    Section(g) { ForEach(AppSection.allCases.filter { $0.group == g }) { sidebarRow($0) } }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let u = model.appUpdate {
                    Link(destination: u.url) {
                        Label("Update available: \(u.count) new change\(u.count == 1 ? "" : "s")", systemImage: "arrow.down.circle.fill").font(.caption)
                    }
                    .help("See what changed on GitHub. To install, pull and run ./build.sh in the source folder.")
                    .padding(8)
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220)
        } detail: {
            Group {
                if search.isEmpty {
                    VStack(spacing: 0) {
                        if model.snapshot.cliAvailable { AskClaudeBar(section: model.section).id(model.section) }
                        detail
                    }
                } else { SearchResultsView(query: search) { search = "" } }
            }
                .navigationTitle(search.isEmpty ? model.section.rawValue : "Search")
                .toolbar {
                    ToolbarItemGroup {
                        let issues = model.issues.filter { model.section == .health || $0.section == model.section }
                        if !issues.isEmpty {
                            Button { copy(Issue.aiPrompt(for: issues)) } label: { Label("Copy AI Prompt", systemImage: "doc.on.clipboard") }
                                .help(promptHelp(Issue.aiPrompt(for: issues)))
                        }
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
        .onChange(of: model.section) { model.info = nil }
        .sheet(item: $model.pendingFix) { FixSheet(pending: $0) }
        .overlay(alignment: .bottom) { UndoToast() }
    }

    @ViewBuilder private var detail: some View {
        switch model.section {
        case .health: ReviewView()
        case .mySkills: SkillsView()
        case .guide: GuideView()
        case .context: ContextView()
        case .analytics: AnalyticsView()
        case .storage: StorageView()
        case .backups: BackupsView()
        case .projects: ProjectsView()
        case .permissions: PermissionsView()
        case .mcp: MCPView()
        case .skills: ComponentsView()
        case .plugins: PluginsView()
        case .hooks: HooksView()
        case .instructions: AgentFilesView()
        case .settings: SettingsView()
        case .discover: DiscoverView()
        }
    }

    private func sidebarRow(_ s: AppSection) -> some View {
        Label(s.rawValue, systemImage: s.symbol)
            .badge(badge(for: s))
            .help(s.term.tooltip)
            .tag(s)
    }

    private func badge(for s: AppSection) -> Int {
        s == .health ? model.issues.filter { $0.severity >= .warning }.count : model.issues.filter { $0.section == s && $0.severity >= .warning }.count
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
        all += s.components.map { Hit(section: $0.kind == .skill ? .mySkills : .skills, title: $0.name, detail: $0.description) }
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
