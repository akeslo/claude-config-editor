import Foundation

public enum LibraryScreen: String, CaseIterable, Hashable, Sendable { case catalogue = "Skills catalogue", backups = "Backups", disk = "Disk" }

/// One sidebar destination: the overview, one provider's config kind, or a Library page.
public enum Screen: Hashable, Sendable {
    case overview, kind(ProviderID, ConfigKind), library(LibraryScreen)

    /// Overview, then one group per detected provider (only its supported kinds, in `ConfigKind` order), then Library.
    public static func sidebar(for detected: [(any Provider, Detection)]) -> [(title: String, screens: [Screen])] {
        [("Overview", [.overview])]
            + detected.map { p, _ in (p.displayName, ConfigKind.allCases.filter(p.supportedKinds.contains).map { .kind(p.id, $0) }) }
            + [("Library", LibraryScreen.allCases.map { .library($0) })]
    }

    /// `overview`, `library/<disk|backups|catalogue>` or `<provider id>/<kind>` (the `-screen` launch argument).
    public static func parse(_ s: String) -> Screen? {
        let p = s.split(separator: "/").map(String.init)
        if p == ["overview"] { return .overview }
        guard p.count == 2 else { return nil }
        if p[0] == "library" { return LibraryScreen.allCases.first { "\($0)" == p[1] }.map { .library($0) } }
        return ConfigKind(rawValue: p[1]).map { .kind(ProviderID(rawValue: p[0]), $0) }
    }

    public var provider: ProviderID? { if case .kind(let p, _) = self { p } else { nil } }

    /// The Claude-era section whose issues, explanations and screen text this screen uses.
    public var section: AppSection {
        switch self {
        case .overview: .health
        case .library(.catalogue): .discover
        case .library(.backups): .backups
        case .library(.disk): .storage
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
        case .health: self = .overview
        case .discover: self = .library(.catalogue)
        case .backups: self = .library(.backups)
        case .storage, .projects: self = .library(.disk)
        case .settings: self = .kind(.claude, .settings)
        case .instructions: self = .kind(.claude, .memory)
        case .skills: self = .kind(.claude, .skills)
        case .agents: self = .kind(.claude, .agents)
        case .mcp: self = .kind(.claude, .mcp)
        case .hooks: self = .kind(.claude, .hooks)
        case .permissions: self = .kind(.claude, .permissions)
        case .plugins: self = .kind(.claude, .plugins)
        }
    }

    public var title: String {
        switch self {
        case .overview: "Overview"
        case .library(let l): l.rawValue
        case .kind(_, let k):
            switch k {
            case .mcp: "MCP"
            default: k.rawValue.capitalized
            }
        }
    }

    public var symbol: String {
        switch self {
        case .kind(_, .commands): "terminal"
        case .library(.disk): "internaldrive"
        case .library(.catalogue): "books.vertical"
        default: section.symbol
        }
    }
}
