import ConfigCore
import SwiftUI

/// Every skill as a card, grouped by a keyword category.
struct SkillGridView: View {
    @Environment(AppModel.self) private var model
    let skills: [Component]
    @State private var filter = ""
    @State private var source = "All"
    @State private var agent: SkillAgent?

    var body: some View {
        @Bindable var model = model
        let picked = model.pickedSkills
        let shown = skills
            .filter { source == "All" || (source == "Plugins") == !$0.ownsFile }
            .filter { agent == nil || $0.agents.contains(agent!) }
            .filter { filter.isEmpty || [$0.name, $0.description, $0.category, $0.belongsTo].contains { $0.localizedCaseInsensitiveContains(filter) } }
        let groups = Dictionary(grouping: shown, by: \.category).sorted { $0.key == "Other" ? false : $1.key == "Other" ? true : $0.key < $1.key }
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
                .fixedSize()
                Picker("Agent", selection: $agent) {
                    Text("All agents").tag(SkillAgent?.none)
                    ForEach(SkillAgent.allCases, id: \.self) { Text($0.rawValue).tag(SkillAgent?.some($0)) }
                }
                .fixedSize()
                Spacer()
                Text("\(shown.count) skills in \(groups.count) categories").font(.callout).foregroundStyle(.secondary)
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
            Text(skill.whenToUse).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            Spacer(minLength: 0)
            HStack(spacing: Space.s) {
                Label(skill.belongsTo, systemImage: skill.ownsFile ? "person" : "shippingbox").lineLimit(1)
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
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
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
        if overlaps.isEmpty {
            ContentUnavailableView("No overlaps", systemImage: "checkmark.circle", description: Text("No two skills share a name or a near-identical description."))
        } else {
            List(overlaps) { o in
                VStack(alignment: .leading, spacing: Space.s) {
                    Label(o.reason, systemImage: o.kind == .sameName ? "doc.on.doc" : "equal.circle").font(.headline)
                    ForEach(o.skills) { s in
                        HStack(spacing: Space.m) {
                            Text("/" + s.name).font(.body.monospaced())
                            Text(s.belongsTo).foregroundStyle(.secondary)
                            Text(s.usageCount == 0 ? "never used" : "used \(s.usageCount)×").foregroundStyle(.secondary).monospacedDigit()
                            Spacer()
                            if s.id == o.keep.id {
                                Text("Keep").foregroundStyle(.green).help("Most used copy")
                            } else if s.ownsFile {
                                // skillOverrides is keyed by name, so Off would also hit a same-named copy: offer it only for look-alikes.
                                if o.kind == .similar, let fix = s.fix(to: .onDemand) {
                                    Button("Make On demand…") { model.propose("Make \(s.name) On demand", fix) }
                                }
                                ConfirmDeleteButton(url: trashURL(s))
                            } else {
                                Text("Plugin skill: turn its plugin off in Plugins").font(.caption).foregroundStyle(.secondary)
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
