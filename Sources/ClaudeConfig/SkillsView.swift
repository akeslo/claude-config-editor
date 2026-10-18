import ConfigCore
import SwiftUI

/// Skills as three plain states, with suggestions from real usage and a cheat sheet so on-demand skills aren't forgotten.
struct SkillsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("skillsPage2") private var page = Page.grid
    @State private var filter = ""

    enum Page: String, CaseIterable {
        case grid = "By category", states = "Always available", cheatSheet = "On demand", overlaps = "Overlaps", map = "Skill map"
        var explanation: String {
            switch self {
            case .grid: "Every skill you have, grouped by what it is for."
            case .states: "Always available skills are listed in every session so Claude can pick them itself; each costs its description in tokens."
            case .cheatSheet: "On demand skills are not listed and cost nothing; they run only when you type /name."
            case .overlaps: "Skills with the same name or near-identical descriptions compete for the same requests; keep one."
            case .map: "Word size is how many times you have used each skill."
            }
        }
    }

    private var skills: [Component] { uniqueSkills(model.snapshot.components) }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Page", selection: $page) {
                ForEach(Page.allCases, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            .padding(.top, Space.m)
            Text(page.explanation).font(.callout).foregroundStyle(.secondary).padding(.vertical, Space.s)
            Divider()
            switch page {
            case .grid: SkillGridView(skills: skills)
            case .overlaps: SkillOverlapsView(skills: skills)
            case .states: StatesPage(skills: skills)
            case .map: SkillMapView()
            case .cheatSheet: CheatSheet(skills: skills.filter { $0.state == .onDemand }, filter: $filter)
            }
        }
    }
}

/// One table row: a skill plus the values its columns sort on.
private struct SkillRow: Identifiable {
    let skill: Component
    let suggestion: SkillSuggestion?
    let stars: Int?
    let source: String
    var id: String { skill.id }
    var name: String { skill.name }
    var stateRank: Int { SkillState.allCases.firstIndex(of: skill.state) ?? 0 }
    var tokens: Int { skill.listingTokens }
    var uses: Int { skill.usageCount }
    var lastUsed: Date { skill.lastUsed ?? .distantPast }
    var installed: Date { skill.installedAt ?? .distantPast }
    var starCount: Int { stars ?? -1 }
    var suggestionText: String { suggestion?.label ?? "" }
}

private struct StatesPage: View {
    @Environment(AppModel.self) private var model
    let skills: [Component]
    @State private var order = [KeyPathComparator(\SkillRow.tokens, order: .reverse)]
    @State private var filter = ""
    @State private var stateFilter: SkillState?
    @State private var sourceFilter = "All"

    var body: some View {
        let triage = skillSuggestions(model.snapshot.components, projects: model.snapshot.projects.map(\.path))
        let suggested = skills.filter { triage[$0.id]?.state != nil }
        let advice = skills.filter { triage[$0.id] != nil && triage[$0.id]?.state == nil }.count
        let saving = suggested.filter { triage[$0.id]?.state != .always }.reduce(0) { $0 + $1.listingTokens }
        let total = skills.reduce(0) { $0 + $1.listingTokens }
        let rows = skills
            .filter { stateFilter == nil || $0.state == stateFilter }
            .filter { sourceFilter == "All" || (sourceFilter == "Plugins") == !$0.ownsFile }
            .filter { filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter) || $0.description.localizedCaseInsensitiveContains(filter) }
            .map { SkillRow(skill: $0, suggestion: triage[$0.id], stars: githubSlug($0.repoURL).flatMap { model.stars[$0] }, source: source($0)) }
            .sorted(using: order)
            Table(rows, sortOrder: $order) {
                TableColumn("Skill", value: \.name) { r in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("/" + r.name).font(.body.weight(.medium).monospaced())
                        Text(purpose(r.skill)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .help(r.skill.description)
                    .contextMenu {
                        Button("Copy /\(r.name)") { copy("/" + r.name) }
                        Button("Open SKILL.md") { openFile(r.skill.file) }
                        Button("Reveal in Finder") { reveal(r.skill.file) }
                    }
                }
                .width(min: 180, ideal: 260)
                TableColumn("State", value: \.stateRank) { r in StatePicker(model: model, skill: r.skill) }
                    .width(min: 220, ideal: 230)
                TableColumn("Tokens", value: \.tokens) { r in
                    Text(r.skill.state == .always ? formatTokens(r.tokens) : "0")
                        .monospacedDigit().foregroundStyle(r.skill.state == .always ? .primary : .secondary)
                        .help(r.skill.state == .always ? "Per session" : "Always would cost \(formatTokens(r.skill.tokens(in: .always)))")
                }
                .width(min: 50, ideal: 60)
                TableColumn("Uses", value: \.uses) { r in Text(r.uses == 0 ? "—" : "\(r.uses)").monospacedDigit() }
                    .width(min: 40, ideal: 50)
                TableColumn("Last Used", value: \.lastUsed) { r in Text(relative(r.skill.lastUsed)).foregroundStyle(.secondary) }
                    .width(min: 70, ideal: 100)
                TableColumn("Installed", value: \.installed) { r in
                    Text(r.skill.installedAt?.formatted(date: .abbreviated, time: .omitted) ?? "—").foregroundStyle(.secondary)
                }
                .width(min: 70, ideal: 100)
                TableColumn("Stars", value: \.starCount) { r in
                    if let repo = r.skill.repoURL, let slug = githubSlug(repo) {
                        Link(destination: repo) {
                            Label(r.stars.map { $0.formatted(.number.notation(.compactName)) } ?? "GitHub", systemImage: "star")
                        }
                        .help("\(slug) on GitHub")
                    }
                }
                .width(min: 50, ideal: 70)
                TableColumn("Source", value: \.source) { r in Text(r.source).foregroundStyle(.secondary).lineLimit(1).help(r.source) }
                    .width(min: 70, ideal: 110)
                TableColumn("Suggestion", value: \.suggestionText) { r in
                    if let s = r.suggestion {
                        VStack(alignment: .leading, spacing: 2) {
                            Label(s.label, systemImage: s.state != nil ? "lightbulb" : s.action == .removeDuplicate ? "doc.on.doc" : "folder").foregroundStyle(Color.accentColor)
                            Text(s.reason).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .help(s.reason)
                    }
                }
                .width(min: 140, ideal: 240)
                TableColumn("") { r in
                    if r.skill.ownsFile {
                        Button("Uninstall…", systemImage: "trash") { model.proposeTrash([trashURL(r.skill)]) }
                            .labelStyle(.iconOnly).buttonStyle(.borderless)
                            .help("Uninstall /\(r.name): moves its folder to the Trash (recoverable)")
                    }
                }
                .width(28)
            }
            .overlay { if rows.isEmpty && !skills.isEmpty { ContentUnavailableView.search(text: filter) } }
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Space.s) {
                Text("Skills cost \(formatTokens(total)) every session").font(.title.weight(.semibold))
                Text("Always available skills are listed so Claude can pick them. On demand skills cost nothing and still run when you type /name.")
                    .foregroundStyle(.secondary).lineLimit(2)
                AIReviewPanel().padding(.top, Space.s)
                if !suggested.isEmpty || advice > 0 {
                    HStack(spacing: Space.m) {
                        if !suggested.isEmpty {
                            Button("Accept \(suggested.count) Suggestion\(suggested.count == 1 ? "" : "s")") {
                                model.propose("Apply \(suggested.count) skill suggestion\(suggested.count == 1 ? "" : "s")",
                                              .many(suggested.compactMap { s in triage[s.id]?.state.flatMap(s.fix(to:)) }))
                            }
                            .buttonStyle(.borderedProminent).controlSize(.large)
                            Text("saves \(formatTokens(saving)) per session").foregroundStyle(.secondary)
                        }
                        if advice > 0 {
                            Text("\(advice) more need\(advice == 1 ? "s" : "") a manual step: see the Suggestion column")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, Space.s)
                }
            }
            .padding(Space.l)
            HStack(spacing: Space.m) {
                TextField("Filter skills", text: $filter).textFieldStyle(.roundedBorder).frame(maxWidth: 280)
                Picker("State", selection: $stateFilter) {
                    Text("All states").tag(SkillState?.none)
                    ForEach(SkillState.allCases, id: \.self) { Text($0.rawValue).tag(SkillState?.some($0)) }
                }
                .frame(width: 200)
                Picker("From", selection: $sourceFilter) {
                    Text("All sources").tag("All")
                    Text("Personal & project").tag("Mine")
                    Text("Plugins").tag("Plugins")
                }
                .fixedSize()
                .help("Plugin skills follow their plugin; manage those plugins in the list below")
                Spacer()
                Text("\(rows.count) of \(skills.count)").font(.callout).foregroundStyle(.secondary)
            }
            .padding(.horizontal, Space.l).padding(.bottom, Space.m)
                }
                .background(.background)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { Button("Plugins are turned on or off in Plugins") { model.section = .plugins }.buttonStyle(.link).padding(Space.s).frame(maxWidth: .infinity, alignment: .leading).background(.background) }
        .task { await model.loadStars() }
    }

    private func source(_ c: Component) -> String {
        switch c.scope {
        case .user: "Personal"
        case .external: c.belongsTo
        case .project: c.owner.map { ($0 as NSString).lastPathComponent } ?? "Project"
        default: "Plugin " + (c.owner?.split(separator: "@").first.map(String.init) ?? "")
        }
    }
}

/// Always / On demand / Off for personal and project skills; plugin skills follow their plugin.
private struct StatePicker: View {
    let model: AppModel   // passed in: Table cells don't receive the Observable environment
    let skill: Component

    var body: some View {
        if skill.ownsFile {
            Picker("State", selection: Binding(get: { skill.state }, set: { target in
                if let fix = skill.fix(to: target) { model.propose("Make \(skill.name) \(target.rawValue)", fix) }
            })) {
                ForEach(SkillState.allCases, id: \.self) { s in Text(s == .always ? "Always" : s.rawValue).tag(s).help(s.explanation) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
        } else {
            Text("Always (plugin)").foregroundStyle(.secondary).help("Plugin skills follow their plugin: turn the plugin off below")
        }
    }
}


/// Every on-demand skill with its /command and one-line purpose: searchable and copyable.
private struct CheatSheet: View {
    let skills: [Component]
    @Binding var filter: String

    var body: some View {
        let shown = skills
            .filter { filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter) || $0.description.localizedCaseInsensitiveContains(filter) }
            .sorted { $0.name < $1.name }
        VStack(spacing: 0) {
            HStack(spacing: Space.m) {
                TextField("Filter on-demand skills", text: $filter).textFieldStyle(.roundedBorder).frame(maxWidth: 320)
                Spacer()
                Button("Copy List", systemImage: "doc.on.doc") { copy(shown.map { "/\($0.name) — \(purpose($0))" }.joined(separator: "\n")) }
                    .disabled(shown.isEmpty)
                    .help("Copies every shown /command with its purpose, one per line")
            }
            .padding(Space.l)
            if skills.isEmpty {
                ContentUnavailableView("No on-demand skills yet", systemImage: "wand.and.rays",
                                       description: Text("Skills you switch to On demand appear here, so you can find them when you need them."))
            } else if shown.isEmpty {
                ContentUnavailableView.search(text: filter)
            } else {
                List(shown) { s in
                    HStack(alignment: .firstTextBaseline, spacing: Space.l) {
                        Text("/" + s.name).font(.body.monospaced()).textSelection(.enabled)
                            .frame(minWidth: 200, alignment: .leading)
                        Text(purpose(s)).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                        Button("Copy", systemImage: "doc.on.doc") { copy("/" + s.name) }
                            .labelStyle(.iconOnly).buttonStyle(.borderless)
                            .help("Copy /\(s.name)")
                    }
                    .padding(.vertical, Space.xs)
                }
                .listStyle(.inset)
            }
        }
    }
}

/// First sentence of the description, as a one-line purpose.
func purpose(_ s: Component) -> String {
    let d = s.description.trimmingCharacters(in: .whitespaces)
    guard let end = d.range(of: ". ") else { return d }
    return String(d[..<end.lowerBound])
}
