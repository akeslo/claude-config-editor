import ConfigCore
import SwiftUI

/// Best practices per area, with what the user has in each ("what you have") beside it.
struct GuideView: View {
    @Environment(AppModel.self) private var model
    @State private var area: AppSection = .mySkills

    private func count(_ a: AppSection) -> Int {
        let s = model.snapshot
        switch a {
        case .mySkills: return s.components.filter { $0.kind == .skill }.count
        case .plugins: return s.plugins.count
        case .mcp: return s.mcpServers.count
        case .hooks: return s.hooks.count
        case .instructions: return s.instructions.count
        case .settings: return s.settings.count
        case .permissions: return s.permissions.count
        default: return 0
        }
    }

    private let areas: [(AppSection, String)] = [
        (.mySkills, "Skills"), (.plugins, "Plugins"), (.mcp, "MCP servers"), (.hooks, "Hooks"),
        (.instructions, "Instructions"), (.settings, "Settings files"), (.permissions, "Permissions"),
    ]

    var body: some View {
        HStack(spacing: 0) {
            List(areas, id: \.0, selection: Binding(get: { area }, set: { area = $0 ?? area })) { a, name in
                HStack { Text(name); Spacer(); Text("\(count(a))").foregroundStyle(.secondary).monospacedDigit() }
                    .tag(a)
            }
            .frame(width: 220)
            Divider()
            ScrollView {
                let rules = model.advice.rules(for: area)
                VStack(alignment: .leading, spacing: Space.l) {
                    if rules.isEmpty {
                        ContentUnavailableView("No advice yet", systemImage: "book", description: Text("Nothing sourced for this area."))
                    }
                    ForEach(rules) { ruleRow($0) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Space.l)
            }
        }
        .navigationTitle("Guide")
    }

    private func ruleRow(_ rule: AdviceRule) -> some View {
        let host = (rule.source.host ?? "").replacingOccurrences(of: "www.", with: "", options: .anchored)
        let result = rule.measure(model.snapshot)
        return VStack(alignment: .leading, spacing: Space.xs) {
            Text(rule.text).font(.headline)
            if let why = rule.why { Text(why).foregroundStyle(.secondary) }
            HStack(spacing: Space.s) {
                Link("\(rule.kind == .official ? "Official" : "Community") · \(host)", destination: rule.source)
                if let result {
                    Label(result.note, systemImage: result.met ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(result.met ? Color.green : Color.orange)
                }
            }.font(.caption)
            Divider().padding(.top, Space.s)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
