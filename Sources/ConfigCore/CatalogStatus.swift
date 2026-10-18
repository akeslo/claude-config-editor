import Foundation

/// A catalog's state (Discover's plugins, community lists). An empty catalog on a fresh profile is
/// `notSetUp`, never a failure: only something that worked before, or was set up, can be disconnected.
public enum CatalogStatus: Equatable, Sendable {
    case notSetUp, connecting, connected, disconnected

    public var isWarning: Bool { self == .disconnected }

    public static func resolve(loading: Bool, rows: Int, setUp: Bool, wasConnected: Bool) -> CatalogStatus {
        if loading { return .connecting }
        if rows > 0 { return .connected }
        return setUp || wasConnected ? .disconnected : .notSetUp
    }

    /// At least one plugin marketplace has been added.
    public static func marketplacesSetUp(claudeDir: URL = Paths.claudeDir) -> Bool {
        !(readJSON(claudeDir.appending(path: "plugins/known_marketplaces.json")) ?? [:]).isEmpty
    }

    /// A community list was fetched on this profile before.
    public static func communityCached(claudeDir: URL = Paths.claudeDir) -> Bool {
        !((try? FileManager.default.contentsOfDirectory(atPath: claudeDir.appending(path: "config-editor-community").path)) ?? []).isEmpty
    }
}
