import ConfigCore
import SwiftUI

/// Skills screen: what to prune, merge or demote. Facts first (computed, verified), then Claude's unverified suggestions.
struct CleanupReviewPanel: View {
    @Environment(AppModel.self) private var model
    @AppStorage("cleanupReviewExpanded") private var expanded = true
    @State private var facts: [SkillFacts] = []
    @State private var sel = BulkSelection<String>()

    var body: some View {
        let findings = cleanupFindings(facts, plugins: model.snapshot.plugins)
        let skills = model.snapshot.components.filter { $0.kind == .skill }
        let advice = (model.analysis?.advice ?? []).compactMap { ad -> (SkillAnalysis.Advice, Component, Fix)? in
            guard let c = skills.first(where: { $0.name == ad.skill }), let s = SkillState(rawValue: ad.state), s != .always, let fix = c.fix(to: s) else { return nil }
            return (ad, c, fix)
        }
        let visible = findings.map(\.id)
        DisclosureGroup(isExpanded: $expanded) {
            ScrollView { VStack(alignment: .leading, spacing: Space.xs) {
                Label("Facts from your usage data (\(findings.count))", systemImage: "checkmark.seal").font(.caption.weight(.semibold))
                BulkBar(sel: $sel, visible: visible, actions: actions(findings)).padding(.horizontal, -Space.l)
                if findings.isEmpty { Text("Nothing to clean up.").font(.callout).foregroundStyle(.secondary) }
                ForEach(findings) { f in
                    HStack(spacing: Space.s) {
                        SelectBox(sel: $sel, id: f.id, visible: visible, name: f.title)
                        Text(f.kind.rawValue).font(.caption).foregroundStyle(.secondary).frame(width: 170, alignment: .leading)
                        Text(f.title).font(.callout.monospaced()).lineLimit(1)
                        Text(f.why).font(.caption).foregroundStyle(.secondary).lineLimit(1).help(f.why)
                        Spacer()
                        if let a = f.action { actionButton(a) }
                    }
                }
                Divider().padding(.vertical, Space.xs)
                HStack {
                    Label("Claude's clean-up suggestions", systemImage: "sparkles").font(.caption.weight(.semibold))
                    Text("unverified AI suggestions").font(.caption).foregroundStyle(.orange)
                }
                if let e = model.analysisError { Label(e, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary) }
                if model.analysis == nil && !model.analyzing && model.analysisError == nil {
                    Text("No review yet. Ask Claude which skills to prune, merge or demote.").foregroundStyle(.secondary)
                }
                ForEach(advice, id: \.0) { ad, c, fix in
                    HStack(spacing: Space.s) {
                        Text("/" + c.name).font(.callout.monospaced())
                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                        Text(ad.state).font(.callout.weight(.medium))
                        Text("\(ad.reason) · \(formatTokens(c.listingTokens)) tokens, \(c.usageCount) uses, last \(relative(c.lastUsed))")
                            .font(.callout).foregroundStyle(.secondary).lineLimit(1).help(ad.reason)
                        Spacer()
                        Button("Apply") { model.propose("Make \(c.name) \(ad.state)", fix) }.controlSize(.small)
                    }
                }
            }
            .padding(.top, Space.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 240)
            .bulkKeys($sel, visible: visible)
        } label: {
            HStack(spacing: Space.s) {
                Label("Clean-up review", systemImage: "scissors").font(.headline)
                if model.analyzing { ProgressView().controlSize(.small) }
                else if let a = model.analysis { Text("AI part: unverified AI suggestions · \(a.date.formatted(.relative(presentation: .named)))").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button(model.analysis == nil ? "Review Now" : "Refresh") { Task { await model.analyzeSkillsIfNeeded(force: true) } }
                    .controlSize(.small).disabled(model.analyzing)
                    .help("Sends skill names, short descriptions and usage counts to Claude (haiku)")
            }
        }
        .task(id: model.skillFingerprint) {
            let comps = model.snapshot.components
            facts = await Task.detached { skillFacts(comps) }.value
        }
    }

    /// "Apply all suggested fixes", the selection, and the selection split by finding type.
    private func actions(_ findings: [CleanupFinding]) -> [BulkAction] {
        let comps = model.snapshot.components
        let picked = findings.filter { sel.contains($0.id) }
        let fixable = findings.filter { $0.action != nil }
        func apply(_ title: String, _ fs: [CleanupFinding]) { model.proposeBulk(title, cleanupPlan(fs, components: comps, plugins: model.snapshot.plugins)) }
        var out = [
            BulkAction(title: "Apply All Suggestions", icon: "wand.and.stars",
                       check: fixable.isEmpty ? .init(enabled: false, why: "No finding has an automatic fix") : .ok) { apply("Apply \(fixable.count) suggested fixes", fixable) },
            BulkAction(title: "Apply to Selected", icon: "checkmark.circle",
                       check: bulkCheck(picked) { $0.action == nil ? "have no automatic fix" : nil }) { apply("Fix \(picked.count) findings", picked) },
        ]
        for kind in CleanupFinding.Kind.allCases {
            let group = picked.filter { $0.kind == kind && $0.action != nil }
            if !group.isEmpty, group.count < picked.count {
                out.append(BulkAction(title: "\(kind.rawValue): fix \(group.count)") { apply("\(kind.rawValue): fix \(group.count)", group) })
            }
        }
        return out
    }

    @ViewBuilder private func actionButton(_ a: CleanupFinding.Action) -> some View {
        let comp = { (id: String) in model.snapshot.components.first { $0.id == id } }
        switch a {
        case .makeCallOnly(let id):
            if let c = comp(id), let fix = c.fix(to: .onDemand) { Button("Make On Demand") { model.propose("Make \(c.name) On demand", fix) }.controlSize(.small) }
        case .turnOff(let id):
            if let c = comp(id), let fix = c.fix(to: .off) { Button("Turn Off") { model.propose("Turn \(c.name) off", fix) }.controlSize(.small) }
        case .uninstall(let id):
            if let c = comp(id) { Button("Move to Trash") { model.proposeTrash([trashURL(c)]) }.controlSize(.small) }
        case .keepOne(let keep, let remove):
            let urls = remove.compactMap(comp).map(trashURL)
            Button("Keep \(comp(keep)?.belongsTo ?? "one")…") { model.proposeTrash(urls) }.controlSize(.small).disabled(urls.isEmpty)
                .help("Moves the other copies to the Trash after you confirm")
        case .uninstallPlugin(let id):
            Button("Uninstall…") { model.propose("Uninstall \(id)", cleanupFix(.uninstallPlugin(id), components: [], plugins: model.snapshot.plugins)!) }.controlSize(.small)
        }
    }
}

/// Discover: Claude's picks of plugins to add, installed through the same rows as the Ask answers.
struct DiscoverReviewPanel: View {
    @Environment(AppModel.self) private var model
    @AppStorage("aiReviewExpanded") private var expanded = true
    @State private var sel = BulkSelection<String>()

    var body: some View {
        let a = model.analysis
        let items = Recommendations.match((a?.discover ?? []).map { .init(kind: "plugin", name: $0.plugin, marketplace: nil, reason: $0.reason) },
                                          available: model.available, community: model.community)
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 0) {
                if let e = model.analysisError { Label(e, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary) }
                if a == nil && !model.analyzing && model.analysisError == nil {
                    Text("No review yet. Ask Claude for plugins that fit how you work.").foregroundStyle(.secondary)
                }
                if !items.isEmpty { BulkBar(sel: $sel, visible: items.map(\.id), actions: model.installActions(items.filter { sel.contains($0.id) })).padding(.horizontal, -Space.l) }
                ForEach(items) { RecommendationRow(item: $0, sel: $sel, visible: items.map(\.id)) }
                ForEach((a?.discover ?? []).filter { p in !items.contains { $0.id.localizedCaseInsensitiveContains(p.plugin) } }, id: \.self) { p in
                    Text("\(p.plugin): \(p.reason) (not in the loaded catalog)").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.top, Space.xs).frame(maxWidth: .infinity, alignment: .leading)
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
        .padding(.horizontal, Space.l).padding(.bottom, Space.s)
    }
}
