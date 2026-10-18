import ConfigCore
import SwiftUI

/// The first screen: what breaks best practice, ranked security → broken → context cost, each with one action.
struct ReviewView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("reviewTab") private var tab = "findings"

    var body: some View {
        VStack(spacing: 0) {
            Picker("View", selection: $tab) {
                Text("Findings").tag("findings")
                Text("Problems & Cleanup").tag("problems")
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize().padding(.vertical, Space.m)
            Divider()
            if tab == "problems" { ProblemsView() } else { FindingsList() }
        }
    }
}

/// Things that failed to load, plus stale items, each with one cleanup action (fix, delete with undo, or edit).
struct ProblemsView: View {
    @Environment(AppModel.self) private var model
    @State private var editing: ProblemEdit?

    var body: some View {
        let failed = model.issues.filter { $0.category == .broken }
        let stale = Failures.stale(model.snapshot)
        List {
            Section {
                ForEach(failed) { issue in
                    HStack(alignment: .center, spacing: Space.l) {
                        Image(systemName: "xmark.octagon").font(.title2).foregroundStyle(.orange).frame(width: 28)
                        VStack(alignment: .leading, spacing: Space.xs) {
                            Text(issue.title).font(.body.weight(.medium))
                            Text(issue.detail).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                            Text(issue.subject).font(.caption).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer(minLength: Space.l)
                        if let fix = issue.fix { Button("Fix…") { model.propose(issue.title, fix) }.help(fix.summary) }
                        if let t = issue.trashable { ConfirmDeleteButton(url: t) }
                        else if let f = issue.file, issue.fix == nil { Button("Edit…") { editing = ProblemEdit(url: f) } }
                    }.padding(.vertical, Space.s)
                }
            } header: { Text("Failed to load (\(failed.count))").font(.headline) }
            Section {
                ForEach(stale, id: \.url) { item in
                    HStack(spacing: Space.l) {
                        Image(systemName: "clock.badge.exclamationmark").font(.title2).foregroundStyle(.secondary).frame(width: 28)
                        VStack(alignment: .leading, spacing: Space.xs) {
                            Text(item.name).font(.body.weight(.medium))
                            Text(item.reason).font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: Space.l)
                        ConfirmDeleteButton(url: item.url)
                    }.padding(.vertical, Space.s)
                }
            } header: { Text("Stale (\(stale.count))").font(.headline) }
        }
        .listStyle(.inset)
        .overlay { if failed.isEmpty && stale.isEmpty && !model.loading { ContentUnavailableView("Nothing failed, nothing stale", systemImage: "checkmark.seal") } }
        .sheet(item: $editing) { FileEditorSheet(url: $0.url) }
    }
}

private struct ProblemEdit: Identifiable { let url: URL; var id: String { url.path } }

struct FindingsList: View {
    @Environment(AppModel.self) private var model

    /// Problems and warnings, plus anything with a context cost. Info-level tidying stays on its own page.
    private var findings: [Issue] {
        model.issues.filter { $0.severity >= .warning || $0.category == .context }
            .sorted { ($0.category, -$0.severity.rawValue, -$0.tokens) < ($1.category, -$1.severity.rawValue, -$1.tokens) }
    }

    var body: some View {
        let findings = findings
        List {
            Section {
                header(findings)
                    .listRowSeparator(.hidden)
                    .padding(.vertical, Space.l)
            }
            ForEach(Issue.Category.allCases, id: \.self) { cat in
                let group = findings.filter { $0.category == cat }
                if !group.isEmpty {
                    Section {
                        ForEach(group) { FindingRow(issue: $0) }
                    } header: {
                        Label(cat.title, systemImage: cat.symbol).font(.headline).foregroundStyle(.primary)
                            .padding(.top, Space.m)
                    }
                }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .overlay {
            if findings.isEmpty && !model.loading {
                ContentUnavailableView("Your setup follows best practice", systemImage: "checkmark.seal",
                                       description: Text("No security, broken-config or context-cost findings."))
                    .padding(.top, 120)
            }
        }
    }

    private func header(_ findings: [Issue]) -> some View {
        let urgent = findings.filter { $0.category <= .broken }.count
        let skills = model.snapshot.components.filter { $0.kind == .skill }.reduce(0) { $0 + $1.listingTokens }
        return VStack(alignment: .leading, spacing: Space.s) {
            Text(findings.isEmpty ? "All clear" : urgent > 0 ? "\(urgent) thing\(urgent == 1 ? "" : "s") to fix first" : "\(findings.count) way\(findings.count == 1 ? "" : "s") to start lighter")
                .font(.largeTitle.weight(.semibold))
            Text("Each session starts with \(formatTokens(model.startupTokens)) of your setup. Skill descriptions are \(formatTokens(skills)) of that.")
                .font(.title3).foregroundStyle(.secondary)
                .help(Term.contextWindow.tooltip)
        }
    }
}

struct FindingRow: View {
    @Environment(AppModel.self) private var model
    let issue: Issue

    private var tint: Color {
        switch issue.category {
        case .security: .red
        case .broken: .orange
        case .context, .tidy: .secondary
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: Space.l) {
            Image(systemName: issue.category.symbol)
                .font(.title2).foregroundStyle(tint).frame(width: 28)
                .accessibilityLabel(issue.category.title)
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(issue.title).font(.body.weight(.medium))
                Text(issue.detail).font(.callout).foregroundStyle(.secondary).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                if let rule = issue.rule.flatMap(model.advice.rule) { adviceLine(rule) }
                Text(issue.subject).font(.caption).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: Space.l)
            if issue.tokens > 0 {
                Text(formatTokens(issue.tokens)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    .help("Context cost per session")
            }
            action.controlSize(.large)
        }
        .padding(.vertical, Space.m)
        .contextMenu {
            Button("Copy AI Prompt") { copy(issue.aiPrompt) }
            if let file = issue.file { Button("Open \(file.lastPathComponent)") { openFile(file) } }
            Button("Go to \(issue.section.rawValue)") { model.section = issue.section }
        }
    }

    private func adviceLine(_ rule: AdviceRule) -> some View {
        let host = (rule.source.host ?? "").replacingOccurrences(of: "www.", with: "", options: .anchored)
        return HStack(spacing: Space.s) {
            if let why = rule.why { Text(why).foregroundStyle(.secondary) }
            Link("\(rule.kind == .official ? "Official" : "Community") · \(host)", destination: rule.source)
        }.font(.caption)
    }

    /// The one obvious next step: apply the fix (with preview), else go to the page where it can be fixed.
    @ViewBuilder private var action: some View {
        if let fix = issue.fix {
            Button("Fix…") { model.propose(issue.title, fix) }.help(fix.summary)
        } else {
            Button("Show") { model.section = issue.section }.help("Go to \(issue.section.rawValue)")
        }
    }
}
