import ConfigCore
import SwiftUI

/// Skills, and the plugins that bring most of them: one table each.
struct SkillsView: View {
    @AppStorage("skillsTab") private var tab = Tab.skills

    enum Tab: String, CaseIterable { case skills = "Skills", plugins = "Plugins" }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Show", selection: $tab) { ForEach(Tab.allCases, id: \.self) { Text($0.rawValue) } }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                .padding(.vertical, Gap.s2)
            Divider()
            switch tab {
            case .skills: SkillsTable()
            case .plugins: PluginsView()
            }
        }
    }
}

/// One table row: a skill plus the values its columns sort on.
private struct SkillRow: Identifiable {
    let skill: Component
    var id: String { skill.id }
    var name: String { skill.name }
    var stateRank: Int { SkillState.allCases.firstIndex(of: skill.state) ?? 0 }
    var tokens: Int { skill.listingTokens }
    var lastUsed: Date { skill.lastUsed ?? .distantPast }
    var source: String { skill.belongsTo }
}

private struct SkillsTable: View {
    @Environment(AppModel.self) private var model
    @State private var order = [KeyPathComparator(\SkillRow.tokens, order: .reverse)]
    @State private var filter = ""
    @State private var stateFilter: SkillState?
    @State private var selection = Set<String>()

    var body: some View {
        let skills = uniqueSkills(model.snapshot.components)
        let total = skills.reduce(0) { $0 + $1.listingTokens }
        let rows = skills
            .filter { stateFilter == nil || $0.state == stateFilter }
            .filter { filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter) || $0.description.localizedCaseInsensitiveContains(filter) }
            .map(SkillRow.init)
            .sorted(using: order)
        Table(rows, selection: $selection, sortOrder: $order) {
            TableColumn("Skill", value: \SkillRow.name) { (r: SkillRow) in
                SkillNameCell(skill: r.skill, purpose: purpose(r.skill), selected: selection.contains(r.id))
                    .scopeRule(ScopeMove.target(of: r.skill).ink(fixed: r.skill.scope == .plugin ? "Plugin" : "Managed"))
            }
            .width(min: 240, ideal: 420)
            TableColumn("State", value: \SkillRow.stateRank) { (r: SkillRow) in StatePicker(model: model, skill: r.skill) }
                .width(min: 110, ideal: 130)
            TableColumn("Tokens", value: \SkillRow.tokens) { (r: SkillRow) in
                Text(r.skill.state == .always ? formatTokens(r.tokens) : "0")
                    .monospacedDigit().foregroundStyle(r.skill.state == .always ? .primary : .secondary)
                    .help(r.skill.state == .always ? "Per session" : "Always would cost \(formatTokens(r.skill.tokens(in: .always)))")
            }
            .width(66)
            TableColumn("Last Used", value: \SkillRow.lastUsed) { (r: SkillRow) in
                Text(relative(r.skill.lastUsed)).foregroundStyle(.secondary).lineLimit(1)
                    .help(r.skill.usageCount == 0 ? "Never used" : "Used \(r.skill.usageCount) times")
            }
            .width(110)
            TableColumn("Scope", value: \SkillRow.source) { (r: SkillRow) in
                ScopeLabel(current: ScopeMove.target(of: r.skill), fixedLabel: r.skill.scope == .plugin ? "Plugin" : r.skill.scope == .external ? "Other agent" : r.skill.scope.rawValue)
                    .help(r.source)
            }
            .width(min: 90, ideal: 140)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            ForEach(model.skillActions(ids)) { a in Button(a.title, action: a.run).disabled(!a.check.enabled) }
            if ids.count == 1, let s = skills.first(where: { ids.contains($0.id) }), let from = ScopeMove.target(of: s) {
                MoveToMenu(current: from, allowLocal: false) { t in model.moveScope("/" + s.name, to: t) { try ScopeMove.move(component: s, to: t) } }
            }
        } primaryAction: { ids in
            if let s = skills.first(where: { ids.contains($0.id) }) { openFile(s.file) }
        }
        .overlay { if rows.isEmpty && !skills.isEmpty { ContentUnavailableView.search(text: filter) } }
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                HStack(spacing: Gap.s3) {
                    TextField("Filter skills", text: $filter).textFieldStyle(.roundedBorder).frame(maxWidth: 280)
                    Picker("State", selection: $stateFilter) {
                        Text("All states").tag(SkillState?.none)
                        ForEach(SkillState.allCases, id: \.self) { Text($0.rawValue).tag(SkillState?.some($0)) }
                    }
                    .labelsHidden().pickerStyle(.menu).fixedSize()
                    Spacer()
                    Text("\(formatTokens(total)) every session · \(rows.count) of \(skills.count)")
                        .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                        .help("Always available skills are listed in every session so Claude can pick them; each costs its description. On demand skills cost nothing until you type /name.")
                }
                .padding(.horizontal, Gap.s4).padding(.vertical, Gap.s2)
                Divider()
            }
            .background(.background)
        }
    }
}

/// Always / On demand / Off for personal and project skills; plugin skills follow their plugin.
struct StatePicker: View {
    let model: AppModel   // passed in: Table cells don't receive the Observable environment
    let skill: Component

    var body: some View {
        if skill.ownsFile {
            Picker("State", selection: Binding(get: { skill.state }, set: { target in
                if let fix = skill.fix(to: target) { model.propose("Make \(skill.name) \(target.rawValue)", fix) }
            })) {
                ForEach(SkillState.allCases, id: \.self) { s in Text(s == .always ? "Always" : s.rawValue).tag(s).help(s.explanation) }
            }
            .pickerStyle(.menu).labelsHidden().fixedSize()
        } else {
            Text("Always").foregroundStyle(.secondary).help("Plugin skills follow their plugin: turn the plugin off on the Plugins tab")
        }
    }
}


extension AppModel {
    func proposeBulk(_ title: String, _ steps: [BulkStep]) { propose(title, .bulk(steps)) }

    /// Actions for the selected skills (the table's context menu).
    func skillActions(_ ids: Set<String>) -> [BulkAction] {
        let picked = snapshot.components.filter { $0.kind == .skill && ids.contains($0.id) }
        let n = "\(picked.count) skill\(picked.count == 1 ? "" : "s")"
        let owned = skillBulkCheck(picked)
        func state(_ t: SkillState, _ title: String, _ icon: String) -> BulkAction {
            BulkAction(title: title, icon: icon, check: owned) { self.proposeBulk("\(title.dropLast()) \(n)", skillStatePlan(picked, to: t)) }
        }
        return [
            state(.onDemand, "Make call-only…", "hand.tap"),
            state(.always, "Make automatic…", "sparkles"),
            state(.off, "Disable…", "nosign"),
            BulkAction(title: "Move to Trash", icon: "trash", check: owned) { self.proposeBulk("Move \(n) to the Trash", skillUninstallPlan(picked)) },
            BulkAction(title: "Copy prompt", icon: "doc.on.clipboard", check: bulkCheck(picked) { _ in nil }) { copy(skillPrompt(picked)) },
        ]
    }
}

/// First sentence of the description, as a one-line purpose.
func purpose(_ s: Component) -> String {
    let d = s.description.trimmingCharacters(in: .whitespaces)
    guard let end = d.range(of: ". ") else { return d }
    return String(d[..<end.lowerBound])
}

/// Name + purpose, with a copy button for the exact slash invocation on hover or selection.
private struct SkillNameCell: View {
    let skill: Component
    let purpose: String
    let selected: Bool
    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text(skill.invocation).font(.body.weight(.medium).monospaced()).lineLimit(1).truncationMode(.middle)
                Text(purpose).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .help(skill.invocation + "\n" + skill.description)
            Spacer(minLength: 0)
            Button {
                copy(skill.invocation)
                copied = true
                Task { try? await Task.sleep(for: .seconds(1.2)); copied = false }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .foregroundStyle(copied ? Color.green : Color.secondary)
            }
            .buttonStyle(.borderless)
            .opacity(hovering || selected || copied ? 1 : 0)
            .help(copied ? "Copied" : "Copy \(skill.invocation)")
            .accessibilityLabel(copied ? "Copied" : "Copy \(skill.invocation)")
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Copy command") { copy(skill.invocation) }
            Button("Open SKILL.md") { openFile(skill.file) }
            Button("Reveal in Finder") { reveal(skill.file) }
        }
    }
}
