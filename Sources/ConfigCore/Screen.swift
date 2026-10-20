import Foundation

/// One sidebar destination: one provider's config kind, or Backups.
public enum Screen: Hashable, Sendable {
    case kind(ProviderID, ConfigKind), backups

    /// Kinds that get their own row: Commands live on the Agents screen, Plugins on Skills.
    static let merged: [ConfigKind: ConfigKind] = [.commands: .agents, .plugins: .skills]

    /// The kinds whose files a screen for `k` shows: itself plus any merged into it.
    public static func kinds(shownOn k: ConfigKind) -> [ConfigKind] { [k] + ConfigKind.allCases.filter { merged[$0] == k } }

    /// One group per detected provider (its supported kinds, merged, in `ConfigKind` order), then Backups.
    public static func sidebar(for detected: [(any Provider, Detection)]) -> [(title: String, screens: [Screen])] {
        detected.map { p, _ in
            let kinds = Set(p.supportedKinds.map { merged[$0] ?? $0 })
            return (p.displayName, ConfigKind.allCases.filter(kinds.contains).map { .kind(p.id, $0) })
        } + [("Library", [.backups])]
    }

    /// `backups` or `<provider id>/<kind>` (the `-screen` launch argument); a merged kind opens its host screen.
    public static func parse(_ s: String) -> Screen? {
        if s == "backups" { return .backups }
        let p = s.split(separator: "/").map(String.init)
        guard p.count == 2, let k = ConfigKind(rawValue: p[1]) else { return nil }
        return .kind(ProviderID(rawValue: p[0]), merged[k] ?? k)
    }

    public var provider: ProviderID? { if case .kind(let p, _) = self { p } else { nil } }

    /// The Claude-era section whose issues, explanations and screen text this screen uses.
    public var section: AppSection {
        switch self {
        case .backups: .backups
        case .kind(_, let k):
            switch k {
            case .settings: .settings
            case .memory: .instructions
            case .skills: .skills
            case .agents, .commands: .agents
            case .mcp: .mcp
            case .hooks: .hooks
            case .permissions: .permissions
            case .plugins: .plugins
            }
        }
    }

    /// Where a legacy section lands (Claude screens).
    public init(_ s: AppSection) {
        switch s {
        case .backups: self = .backups
        case .settings: self = .kind(.claude, .settings)
        case .instructions: self = .kind(.claude, .memory)
        case .skills: self = .kind(.claude, .skills)
        case .agents: self = .kind(.claude, .agents)
        case .mcp: self = .kind(.claude, .mcp)
        case .hooks: self = .kind(.claude, .hooks)
        case .permissions: self = .kind(.claude, .permissions)
        case .plugins: self = .kind(.claude, .skills)
        }
    }

    public var title: String {
        switch self {
        case .backups: "Backups"
        case .kind(_, let k):
            switch k {
            case .mcp: "MCP"
            case .agents: "Agents & Commands"
            default: k.rawValue.capitalized
            }
        }
    }

    public var symbol: String { section.symbol }
}
