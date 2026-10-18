import ConfigCore
import SwiftUI

/// Claude's review from launch: suggested state changes (applied through the FixSheet) and marketplace plugins worth a look.
struct AIReviewPanel: View {
    @Environment(AppModel.self) private var model
    @AppStorage("aiReviewExpanded") private var expanded = true

    var body: some View {
        let a = model.analysis
        let skills = model.snapshot.components.filter { $0.kind == .skill }
        let advice = (a?.advice ?? []).compactMap { ad -> (SkillAnalysis.Advice, Component, Fix)? in
            guard let c = skills.first(where: { $0.name == ad.skill }), let s = SkillState(rawValue: ad.state), let fix = c.fix(to: s) else { return nil }
            return (ad, c, fix)
        }
        DisclosureGroup(isExpanded: $expanded) {
            ScrollView { VStack(alignment: .leading, spacing: Space.xs) {
                if let e = model.analysisError { Label(e, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary) }
                if a == nil && !model.analyzing && model.analysisError == nil {
                    Text("No review yet. Ask Claude to look over your skills and suggest plugins that fit how you work.").foregroundStyle(.secondary)
                }
                ForEach(advice, id: \.0) { ad, c, fix in
                    HStack(spacing: Space.s) {
                        Text("/" + c.name).font(.callout.monospaced())
                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                        Text(ad.state).font(.callout.weight(.medium))
                        Text(ad.reason).font(.callout).foregroundStyle(.secondary).lineLimit(1).help(ad.reason)
                        Spacer()
                        Button("Apply…") { model.propose("Make \(c.name) \(ad.state)", fix) }.controlSize(.small)
                    }
                }
                ForEach(a?.discover ?? [], id: \.self) { p in
                    HStack(spacing: Space.s) {
                        Image(systemName: "sparkles").foregroundStyle(Color.accentColor)
                        Text(p.plugin).font(.callout.weight(.medium))
                        Text(p.reason).font(.callout).foregroundStyle(.secondary).lineLimit(1).help(p.reason)
                        Spacer()
                        if let ap = model.available.first(where: { $0.name == p.plugin }) {
                            Button("Install…") { model.propose("Install \(ap.id)", .cli(args: ["plugin", "install", ap.id], dryRun: nil, cwd: nil)) }
                                .controlSize(.small)
                        }
                    }
                }
            }
            .padding(.top, Space.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 130)
        } label: {
            HStack(spacing: Space.s) {
                Label("Claude's review", systemImage: "sparkles").font(.headline)
                if model.analyzing { ProgressView().controlSize(.small) }
                else if let a { Text("unverified AI suggestions · \(a.date.formatted(.relative(presentation: .named)))").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button(a == nil ? "Review Now" : "Refresh") { Task { await model.analyzeSkillsIfNeeded(force: true) } }
                    .controlSize(.small).disabled(model.analyzing)
                    .help("Sends skill names, short descriptions and usage counts to Claude (haiku)")
            }
        }
    }
}

/// Every skill and plugin as a word: size by use, color by where it comes from. Click a plugin to drill into its skills, a skill to see it.
struct SkillMapView: View {
    @Environment(AppModel.self) private var model
    @State private var plugin: String?
    @State private var selected: Component?
    @State private var search = ""

    enum Source: String, CaseIterable {
        case personal = "Personal", project = "Project", plugin = "Plugin"
        var color: Color { switch self { case .personal: .primary; case .project: .orange; case .plugin: .purple } }
    }

    private func source(_ c: Component) -> Source { c.scope == .user ? .personal : c.scope == .project ? .project : .plugin }

    var body: some View {
        let skills = model.snapshot.components.filter { $0.kind == .skill }
        let plugins = model.snapshot.plugins.filter { p in skills.contains { $0.owner == p.id } }
        // Focal accent on at most two: the most used skills overall.
        let top = Set(skills.filter { $0.usageCount > 0 }.sorted { $0.usageCount > $1.usageCount }.prefix(2).map(\.id))
        let maxUse = Double(max(skills.map(\.usageCount).max() ?? 1, plugins.map(\.usageCount).max() ?? 1, 1))
        let size = { (uses: Int) in 12 + 26 * log(1 + Double(uses)) / log(1 + maxUse) }
        VStack(spacing: 0) {
            HStack(spacing: Space.m) {
                if let plugin {
                    Button("All", systemImage: "chevron.left") { self.plugin = nil }
                    Text(plugin.split(separator: "@").first.map(String.init) ?? plugin).font(.headline)
                }
                TextField("Find a skill", text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 240)
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Based on times used").font(.headline)
                    Text("Bigger word = used more · \(skills.reduce(0) { $0 + $1.usageCount }) uses across \(skills.count) skills").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(Space.l)
            ScrollView {
                FlowLayout(spacing: 10) {
                    if plugin == nil && search.isEmpty {
                        ForEach(plugins) { p in
                            let n = p.id.split(separator: "@").first.map(String.init) ?? p.id
                            Button { plugin = p.id } label: {
                                Label(n + " \(p.usageCount)", systemImage: "shippingbox").font(.system(size: size(p.usageCount), weight: .semibold))
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Source.plugin.color.opacity(0.5)))
                                    .foregroundStyle(p.enabled ? Source.plugin.color : .secondary)
                                    .opacity(p.enabled ? 1 : 0.5)
                            }
                            .buttonStyle(.plain)
                            .help("\(n): \(skills.filter { $0.owner == p.id }.count) skills, used \(p.usageCount)×. Click to see its skills.")
                        }
                    }
                    ForEach(skills.filter { c in
                        (plugin == nil ? (c.ownsFile || !search.isEmpty) : c.owner == plugin)
                            && (search.isEmpty || c.name.localizedCaseInsensitiveContains(search) || c.description.localizedCaseInsensitiveContains(search))
                    }) { c in
                        Button { selected = c } label: {
                            (Text(c.name.split(separator: ":").last.map(String.init) ?? c.name)
                             + Text(" \(c.usageCount)").font(.caption2.monospacedDigit()).foregroundColor(.secondary))
                                .font(.system(size: size(c.usageCount), weight: top.contains(c.id) ? .bold : .regular))
                                .foregroundStyle(top.contains(c.id) ? Color.accentColor : source(c).color)
                                .opacity(c.state == .off ? 0.35 : c.state == .onDemand ? 0.7 : 1)
                                .strikethrough(c.state == .off)
                        }
                        .buttonStyle(.plain)
                        .help("/\(c.name) · \(c.state.rawValue) · used \(c.usageCount)×")
                        .popover(isPresented: Binding(get: { selected?.id == c.id }, set: { if !$0 { selected = nil } })) { SkillCard(skill: c) }
                    }
                }
                .padding(.horizontal, Space.l).padding(.bottom, Space.l)
            }
            Divider()
            HStack(spacing: Space.l) {
                ForEach(Source.allCases, id: \.self) { s in Label(s.rawValue, systemImage: "circle.fill").foregroundStyle(s.color) }
                Label("Most used", systemImage: "circle.fill").foregroundStyle(Color.accentColor)
                Text("Number = times used · faded = On demand · struck = Off").foregroundStyle(.secondary)
                Spacer()
            }
            .font(.caption).labelStyle(LegendLabel()).padding(.horizontal, Space.l).padding(.vertical, Space.s)
        }
    }
}

private struct LegendLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) { configuration.icon.font(.system(size: 7)); configuration.title.foregroundStyle(.secondary) }
    }
}

/// The popover behind a word: what it does and what you can do with it.
private struct SkillCard: View {
    @Environment(AppModel.self) private var model
    let skill: Component

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Text("/" + skill.name).font(.headline.monospaced())
            Text(skill.description).font(.callout).fixedSize(horizontal: false, vertical: true)
            Text("\(skill.state.rawValue) · used \(skill.usageCount)× · last \(relative(skill.lastUsed)) · \(formatTokens(skill.listingTokens)) per session")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Copy /\(skill.name)") { copy("/" + skill.name) }
                if skill.ownsFile {
                    Menu("State") {
                        ForEach(SkillState.allCases.filter { $0 != skill.state }, id: \.self) { s in
                            Button(s.rawValue) { if let f = skill.fix(to: s) { model.propose("Make \(skill.name) \(s.rawValue)", f) } }
                        }
                    }
                    .fixedSize()
                }
                Button("Open SKILL.md") { openFile(skill.file) }
            }
            .controlSize(.small)
        }
        .padding(Space.l)
        .frame(width: 360)
    }
}

/// Left-to-right wrapping layout for the words.
struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? 800, subviews)
        return CGSize(width: proposal.width ?? 800, height: rows.last.map { $0.y + $0.height } ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(width: bounds.width, subviews) {
            for (i, x) in row.items {
                let s = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + row.y + (row.height - s.height) / 2), proposal: .unspecified)
            }
        }
    }

    private func arrange(width: CGFloat, _ subviews: Subviews) -> [(y: CGFloat, height: CGFloat, items: [(Int, CGFloat)])] {
        var rows: [(y: CGFloat, height: CGFloat, items: [(Int, CGFloat)])] = []
        var x: CGFloat = 0, y: CGFloat = 0, h: CGFloat = 0, items: [(Int, CGFloat)] = []
        for (i, v) in subviews.enumerated() {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > width { rows.append((y, h, items)); y += h + spacing; x = 0; h = 0; items = [] }
            items.append((i, x)); x += s.width + spacing; h = max(h, s.height)
        }
        if !items.isEmpty { rows.append((y, h, items)) }
        return rows
    }
}
