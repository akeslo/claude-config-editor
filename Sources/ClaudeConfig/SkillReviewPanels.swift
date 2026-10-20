import ConfigCore
import SwiftUI

/// Skills screen: one fixed-height row with the finding count; the review itself opens in a sheet so the page never reflows.
struct CleanupReviewRow: View {
    @Environment(AppModel.self) private var model
    @State private var facts: [SkillFacts]?
    @State private var open = false

    var body: some View {
        HStack(spacing: PSpace.s2) {
            Label("Clean-up review", systemImage: "scissors").font(.headline)
            Group {
                if let facts {
                    let n = cleanupFindings(facts, plugins: model.snapshot.plugins).count
                    Text(n == 0 ? "nothing to clean up" : "\(n) finding\(n == 1 ? "" : "s")")
                } else { Text("checking…") }
            }
            .font(.callout).foregroundStyle(.secondary).monospacedDigit()
            if model.analysis != nil { Text("· Claude's suggestions ready").font(.callout).foregroundStyle(.secondary) }
            Spacer()
            Button("Review…") { open = true }.disabled(facts == nil)
        }
        .padding(.horizontal, PSpace.s3).frame(height: 40)
        .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
        .sheet(isPresented: $open) {
            VStack(spacing: 0) {
                CleanupReviewPanel(facts: facts ?? []).padding(PSpace.s4)
                Divider()
                HStack { Spacer(); Button("Done") { open = false }.keyboardShortcut(.defaultAction) }.padding(PSpace.s3)
            }
            .frame(width: 760, height: 560)
        }
        .task(id: model.skillFingerprint) {
            let comps = model.snapshot.components
            facts = await Task.detached { skillFacts(comps) }.value
        }
    }
}

/// What to prune, merge or demote. Facts first (computed, verified), then Claude's unverified suggestions.
struct CleanupReviewPanel: View {
    @ScaledMetric private var kindW: CGFloat = 170
    @Environment(AppModel.self) private var model
    let facts: [SkillFacts]
    @State private var sel = BulkSelection<String>()

    var body: some View {
        let findings = cleanupFindings(facts, plugins: model.snapshot.plugins)
        let skills = model.snapshot.components.filter { $0.kind == .skill }
        let advice = (model.analysis?.advice ?? []).compactMap { ad -> (SkillAnalysis.Advice, Component, Fix)? in
            guard let c = skills.first(where: { $0.name == ad.skill }), let s = SkillState(rawValue: ad.state), s != .always, let fix = c.fix(to: s) else { return nil }
            return (ad, c, fix)
        }
        let visible = findings.map(\.id)
        VStack(alignment: .leading, spacing: PSpace.s2) {
            header
            ScrollView { VStack(alignment: .leading, spacing: PSpace.s1) {
                Label("Facts from your usage data (\(findings.count))", systemImage: "checkmark.seal").font(.caption.weight(.semibold))
                BulkBar(sel: $sel, visible: visible, actions: actions(findings)).padding(.horizontal, -PSpace.s4)
                if findings.isEmpty { Text("Nothing to clean up.").font(.callout).foregroundStyle(.secondary) }
                ForEach(findings) { f in
                    HStack(spacing: PSpace.s2) {
                        SelectBox(sel: $sel, id: f.id, visible: visible, name: f.title)
                        Text(f.kind.rawValue).font(.caption).foregroundStyle(.secondary).frame(width: kindW, alignment: .leading)
                        Text(f.title).font(.callout.monospaced()).lineLimit(1)
                        Text(f.why).font(.caption).foregroundStyle(.secondary).lineLimit(1).help(f.why)
                        Spacer()
                        if let a = f.action { actionButton(a) }
                    }
                }
                Divider().padding(.vertical, PSpace.s1)
                HStack {
                    Label("Claude's clean-up suggestions", systemImage: "sparkles").font(.caption.weight(.semibold))
                    Text("unverified AI suggestions").font(.caption).foregroundStyle(PColor.attention.fg)
                }
                if let e = model.analysisError { Label(e, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary) }
                if model.analysis == nil && !model.analyzing && model.analysisError == nil {
                    Text("No review yet. Ask Claude which skills to prune, merge or demote.").foregroundStyle(.secondary)
                }
                ForEach(advice, id: \.0) { ad, c, fix in
                    HStack(spacing: PSpace.s2) {
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
            .padding(.top, PSpace.s1)
            .frame(maxWidth: .infinity, alignment: .leading)
            }
            .bulkKeys($sel, visible: visible)
        }
    }

    private var header: some View {
            HStack(spacing: PSpace.s2) {
                Label("Clean-up review", systemImage: "scissors").font(.headline)
                if model.analyzing { ProgressView().controlSize(.small) }
                else if let a = model.analysis { Text("AI part: unverified AI suggestions · \(a.date.formatted(.relative(presentation: .named)))").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button(model.analysis == nil ? "Review Now" : "Refresh") { Task { await model.analyzeSkillsIfNeeded(force: true) } }
                    .controlSize(.small).disabled(model.analyzing)
                    .help("Sends skill names, short descriptions and usage counts to Claude (haiku)")
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

extension AppModel {
    /// Changes when anything the clean-up review reads changes, so facts are rebuilt only then.
    var skillFingerprint: Int {
        var h = Hasher()
        for c in snapshot.components where c.kind == .skill { h.combine(c.id); h.combine(c.usageCount); h.combine(c.override); h.combine(c.alwaysLoaded); h.combine(c.agents.count) }
        return h.finalize()
    }
}
