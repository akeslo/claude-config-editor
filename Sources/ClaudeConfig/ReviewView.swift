import ConfigCore
import SwiftUI

/// The first screen: what breaks best practice, ranked security → broken → context cost, each with one action.
struct ReviewView: View {
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

    /// The one obvious next step: apply the fix (with preview), else go to the page where it can be fixed.
    @ViewBuilder private var action: some View {
        if let fix = issue.fix {
            Button("Fix…") { model.propose(issue.title, fix) }.help(fix.summary)
        } else {
            Button("Show") { model.section = issue.section }.help("Go to \(issue.section.rawValue)")
        }
    }
}
