import Foundation

/// One shared rule for "is this old/unused/broken": files untouched > 90 days, unused > 60 days, or a missing path.
public enum Staleness: Int, Comparable, Sendable {
    case fresh, aging, stale
    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    public static let staleModifiedDays = 90.0, staleUnusedDays = 60.0
    /// Halfway to stale counts as aging.
    public static let agingModifiedDays = 45.0, agingUnusedDays = 30.0

    /// Pass whatever you know; nil inputs are ignored. Returns the worst level and why.
    public static func of(modified: Date? = nil, lastUsed: Date? = nil, pathExists: Bool = true, now: Date = Date()) -> (level: Staleness, reason: String) {
        if !pathExists { return (.stale, "Path no longer exists") }
        func days(_ d: Date) -> Double { now.timeIntervalSince(d) / 86_400 }
        var result: (Staleness, String) = (.fresh, "")
        if let u = lastUsed {
            let d = days(u)
            if d > staleUnusedDays { result = (.stale, "Not used in \(Int(d)) days") }
            else if d > agingUnusedDays { result = (.aging, "Not used in \(Int(d)) days") }
        }
        if let m = modified, result.0 != .stale {
            let d = days(m)
            if d > staleModifiedDays { result = (.stale, "Not modified in \(Int(d)) days") }
            else if d > agingModifiedDays, result.0 == .fresh { result = (.aging, "Not modified in \(Int(d)) days") }
        }
        return result
    }
}

/// Creation and modification dates of a file (nil when unreadable).
public func fileDates(_ url: URL) -> (created: Date?, modified: Date?) {
    let v = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
    return (v?.creationDate, v?.contentModificationDate)
}
