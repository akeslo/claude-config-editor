import ConfigCore
import SwiftUI

/// Every skill as a card, grouped by a keyword category.
struct SkillGridView: View {
    let skills: [Component]
    @State private var filter = ""
    @State private var source = "All"

    var body: some View {
        let shown = skills
            .filter { source == "All" || (source == "Plugins") == !$0.ownsFile }
            .filter { filter.isEmpty || [$0.name, $0.description, $0.category, $0.belongsTo].contains { $0.localizedCaseInsensitiveContains(filter) } }
        let groups = Dictionary(grouping: shown, by: \.category).sorted { $0.key == "Other" ? false : $1.key == "Other" ? true : $0.key < $1.key }
        VStack(spacing: 0) {
            HStack(spacing: Space.m) {
                TextField("Filter skills", text: $filter).textFieldStyle(.roundedBorder).frame(maxWidth: 280)
                Picker("From", selection: $source) {
                    Text("All sources").tag("All")
                    Text("Personal & project").tag("Mine")
                    Text("Plugins").tag("Plugins")
                }
                .fixedSize()
                Spacer()
                Text("\(shown.count) skills in \(groups.count) categories").font(.callout).foregroundStyle(.secondary)
            }
            .padding(Space.l)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Space.l, pinnedViews: .sectionHeaders) {
                    ForEach(groups, id: \.key) { cat, items in
                        Section {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: Space.m, alignment: .top)], spacing: Space.m) {
                                ForEach(items.sorted { ($0.usageCount, $1.name) > ($1.usageCount, $0.name) }) { SkillGridCard(skill: $0) }
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
        }
    }
}

private struct SkillGridCard: View {
    let skill: Component

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(alignment: .firstTextBaseline) {
                Text("/" + skill.shortName).font(.body.weight(.semibold).monospaced()).lineLimit(1)
                Spacer()
                StaleBadge(Staleness.of(lastUsed: skill.lastUsed ?? skill.installedAt))
            }
            Text(purpose(skill)).font(.callout).lineLimit(2).help(skill.description)
            Text(skill.whenToUse).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            Spacer(minLength: 0)
            HStack(spacing: Space.s) {
                Label(skill.belongsTo, systemImage: skill.ownsFile ? "person" : "shippingbox").lineLimit(1)
                Spacer()
                Text(skill.usageCount == 0 ? "never used" : "used \(skill.usageCount)×").monospacedDigit()
                Text("· " + skill.state.rawValue)
            }
            .font(.caption).foregroundStyle(.secondary)
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
