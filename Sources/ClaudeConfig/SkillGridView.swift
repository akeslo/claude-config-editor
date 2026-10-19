import ConfigCore
import SwiftUI

/// Every skill as a card, grouped by a keyword category.
struct SkillGridView: View {
    @Environment(AppModel.self) private var model
    let skills: [Component]
    @State private var filter = ""
    @State private var source = "All"
    @AppStorage("grid.byPrefix") private var byPrefix = true
    @State private var agent: SkillAgent?

    var body: some View {
        @Bindable var model = model
        let picked = model.pickedSkills
        let shown = skills
            .filter { source == "All" || (source == "Plugins") == !$0.ownsFile }
            .filter { agent == nil || $0.agents.contains(agent!) }
            .filter { filter.isEmpty || [$0.name, $0.description, $0.category, $0.belongsTo].contains { $0.localizedCaseInsensitiveContains(filter) } }
        let groups = byPrefix ? skillGroups(shown).map { (key: $0.name, value: $0.skills) }
            : Dictionary(grouping: shown, by: \.category).sorted { $0.key == "Other" ? false : $1.key == "Other" ? true : $0.key < $1.key }
        // Visible order matches the cards, so ⇧-click ranges follow what's on screen.
        let ordered = groups.map { ($0.key, $0.value.sorted { ($0.usageCount, $1.name) > ($1.usageCount, $0.name) }) }
        let visible = ordered.flatMap { $0.1.map(\.id) }
        VStack(spacing: 0) {
            HStack(spacing: Space.m) {
                TextField("Filter skills", text: $filter).textFieldStyle(.roundedBorder).frame(maxWidth: 280)
                Picker("From", selection: $source) {
                    Text("All sources").tag("All")
                    Text("Personal & project").tag("Mine")
                    Text("Plugins").tag("Plugins")
                }
                .filterPicker()
                Picker("Agent", selection: $agent) {
                    Text("All agents").tag(SkillAgent?.none)
                    ForEach(SkillAgent.allCases, id: \.self) { Text($0.rawValue).tag(SkillAgent?.some($0)) }
                }
                .filterPicker()
                Picker("Group", selection: $byPrefix) { Text("By prefix").tag(true); Text("By category").tag(false) }.filterPicker()
                Spacer()
                Text("\(shown.count) skills in \(groups.count) groups").font(.callout).foregroundStyle(.secondary)
            }
            .padding(Space.l)
            BulkBar(sel: $model.pickedSkills, visible: visible, actions: model.skillActions(picked.ids))
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Space.l, pinnedViews: .sectionHeaders) {
                    ForEach(ordered, id: \.0) { cat, items in
                        Section {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: Space.m, alignment: .top)], spacing: Space.m) {
                                ForEach(items) { s in
                                    SkillGridCard(skill: s, sel: $model.pickedSkills, visible: visible)
                                }
                            }
                        } header: {
                            Text("\(cat)  \(items.count)").font(.headline).padding(.vertical, Space.xs)
                                .frame(maxWidth: .infinity, alignment: .leading).background(.background)
                        }
                    }
                }
                .padding([.horizontal, .bottom], Space.l)
            }
            .overlay { if shown.isEmpty { ContentUnavailableView.search(text: filter) } }
            .focusable().focusEffectDisabled()
            .bulkKeys($model.pickedSkills, visible: visible)
        }
    }
}

private struct SkillGridCard: View {
    @Environment(AppModel.self) private var model
    let skill: Component
    @Binding var sel: BulkSelection<String>
    let visible: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(alignment: .firstTextBaseline) {
                Text("/" + skill.shortName).font(.body.weight(.semibold).monospaced()).lineLimit(1)
                Spacer()
                SelectBox(sel: $sel, id: skill.id, visible: visible, name: "/" + skill.name)
                StaleBadge(Staleness.of(lastUsed: skill.lastUsed ?? skill.installedAt))
            }
            Text(purpose(skill)).font(.callout).lineLimit(2).help(skill.description)
            if skill.whenToUse != purpose(skill) { Text(skill.whenToUse).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
            Spacer(minLength: 0)
            HStack(spacing: Space.s) {
                ScopeMenu(current: ScopeMove.target(of: skill), fixedLabel: skill.scope == .plugin ? "Plugin" : skill.belongsTo, allowLocal: false) { t in
                    model.moveScope("/" + skill.name, to: t) { try ScopeMove.move(component: skill, to: t) }
                }
                .controlSize(.small)
                Spacer()
                Text(skill.usageCount == 0 ? "never used" : "used \(skill.usageCount)×").monospacedDigit()
                if skill.scope == .user, skill.state != .off, let target = Optional(skill.state == .always ? SkillState.onDemand : .always), let fix = skill.fix(to: target) {
                    Button("· " + (skill.state == .always ? "Automatic" : "Only when called")) { model.propose("Make \(skill.name) \(target.rawValue)", fix) }
                        .buttonStyle(.link).help("Click to switch to \(target == .always ? "automatic" : "only when called (/name)")")
                } else {
                    Text("· " + skill.state.rawValue)
                }
            }
            .font(.caption).foregroundStyle(.secondary)
            Text(skill.agents.map(\.rawValue).joined(separator: " · ")).font(.caption2).foregroundStyle(.tertiary)
                .help((skill.locations.isEmpty ? "" : "Also at:\n" + skill.locations.map(shortPath).joined(separator: "\n")))
        }
        .padding(Space.m)
        .frame(maxWidth: .infinity, minHeight: 130, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator, lineWidth: 0.5))
        .contextMenu {
            Button("Copy /\(skill.name)") { copy("/" + skill.name) }
            Button("Open SKILL.md") { openFile(skill.file) }
        }
    }
}

/// Duplicate names and near-identical descriptions, each with the copy to keep and a cleanup action for the rest.
struct SkillOverlapsView: View {
    @Environment(AppModel.self) private var model
    let skills: [Component]

    var body: some View {
        let overlaps = skillOverlaps(skills)
        let all = model.snapshot.components, plugins = model.snapshot.plugins
        if overlaps.isEmpty {
            ContentUnavailableView("No overlaps", systemImage: "checkmark.circle", description: Text("No two skills share a name or a near-identical description."))
        } else {
            VStack(spacing: 0) {
                HStack {
                    Text("\(overlaps.count) overlap\(overlaps.count == 1 ? "" : "s")").foregroundStyle(.secondary)
                    Spacer()
                    Button("Keep the Most-Used Copy of Each", systemImage: "wand.and.stars") {
                        model.proposeBulk("Resolve \(overlaps.count) overlaps, keeping the most-used copy",
                                          overlaps.flatMap { overlapKeepPlan($0, keep: $0.keep, all: all, plugins: plugins) })
                    }
                    .help("Shows every removal in a confirm sheet first; nothing changes until you apply")
                }
                .padding(Space.l)
                Divider()
                List(overlaps) { o in
                    VStack(alignment: .leading, spacing: Space.s) {
                        Label(o.reason, systemImage: o.kind == .sameName ? "doc.on.doc" : "equal.circle").font(.headline)
                        ForEach(o.skills) { s in
                            HStack(spacing: Space.m) {
                                Text("/" + s.name).font(.body.monospaced())
                                Text(s.belongsTo).foregroundStyle(.secondary)
                                Text(s.usageCount == 0 ? "never used" : "used \(s.usageCount)×").foregroundStyle(.secondary).monospacedDigit()
                                if s.id == o.keep.id { Text("most used").font(.caption).foregroundStyle(.tertiary) }
                                Spacer()
                                Button("Keep This One") {
                                    model.proposeBulk("Keep /\(s.name) (\(s.belongsTo)), remove the other\(o.skills.count > 2 ? "s" : "")",
                                                      overlapKeepPlan(o, keep: s, all: all, plugins: plugins))
                                }
                                // skillOverrides is keyed by name, so On demand would also hit a same-named copy: offer it only for look-alikes.
                                if s.ownsFile, o.kind == .similar, let fix = s.fix(to: .onDemand) {
                                    Button("Make On Demand") { model.propose("Make \(s.name) On demand", fix) }
                                }
                                if let r = overlapRemoval(s, all: all, plugins: plugins) {
                                    Button(r.button, role: .destructive) { model.propose(r.title, r.fix) }
                                } else {
                                    Text("No automatic fix").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .controlSize(.small)
                        }
                    }
                    .padding(.vertical, Space.s)
                }
                .listStyle(.inset)
            }
        }
    }
}

/// Copies an agent-neutral prompt naming the selected skills and their SKILL.md paths; flashes "Copied N skills".
struct CopyPromptButton: View {
    let skills: [Component]
    @Binding var picked: BulkSelection<String>
    @State private var copied: Int?

    var body: some View {
        HStack(spacing: Space.s) {
            if let copied { Label("Copied \(copied) skill\(copied == 1 ? "" : "s")", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(Color.accentColor) }
            if !picked.isEmpty { Button("Clear") { picked.clear() }.buttonStyle(.link) }
            Button("Copy prompt (\(skills.count))", systemImage: "doc.on.clipboard") {
                copy(skillPrompt(skills))
                let n = skills.count
                copied = n
                Task { try? await Task.sleep(for: .seconds(1.5)); if copied == n { copied = nil } }
            }
            .disabled(skills.isEmpty)
            .help("Copies a prompt that tells Claude Code, Codex or Gemini to read and use the selected skills. Fill in {task}.")
        }
    }
}
