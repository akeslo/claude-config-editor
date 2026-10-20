import Foundation

/// Key-level edits to settings files with an undoable `Backup` snapshot. Unknown keys are always kept.
public enum SettingsEdit {
    /// Sets (or with `nil` removes) one key path. Refuses if the file changed since `expectedModified` (pass the scan's date).
    /// Returns the pre-write snapshot, nil when the file did not exist yet.
    @discardableResult
    public static func setKey(_ url: URL, path: [String], value: Any?, expectedModified: Date?? = nil, home: URL = Paths.home) throws -> Backup.Record? {
        try mutate(url, expectedModified: expectedModified, home: home) { root in
            ScopeMove.set(&root, path[...], value)
        }
    }

    /// Edits one permission rule: removes `remove` and/or appends `add` (kind = allow/ask/deny). A move is both at once.
    @discardableResult
    public static func editRule(_ url: URL, remove: (kind: String, rule: String)? = nil, add: (kind: String, rule: String)? = nil,
                                expectedModified: Date?? = nil, home: URL = Paths.home) throws -> Backup.Record? {
        try mutate(url, expectedModified: expectedModified, home: home) { root in
            var perms = root["permissions"] as? JSON ?? [:]
            if let r = remove { perms[r.kind] = (perms[r.kind] as? [String] ?? []).filter { $0 != r.rule } }
            if let a = add {
                var list = perms[a.kind] as? [String] ?? []
                if !list.contains(a.rule) { list.append(a.rule) }
                perms[a.kind] = list
            }
            root["permissions"] = perms
        }
    }

    /// Turns typed text into a JSON value: valid JSON (true, 3, "x", {..}, [..]) parses; anything else stays a string.
    public static func parse(_ text: String) -> Any {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let d = t.data(using: .utf8), let v = try? JSONSerialization.jsonObject(with: d, options: .fragmentsAllowed) { return v }
        return text
    }

    /// Pretty JSON for any value (strings quoted), for the object/array editor.
    public static func render(_ v: Any) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: v, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes]) else { return "\(v)" }
        return String(decoding: d, as: UTF8.self)
    }

    /// The source whose value applies if `excluding` loses `key`: highest-precedence other file in the same context.
    /// Project files only count for their own project; user files count everywhere.
    public static func fallback(for key: String, excluding: SettingsSource, in sources: [SettingsSource]) -> SettingsSource? {
        let order: [Scope] = [.managed, .local, .project, .userLocal, .user]
        return sources
            .filter { $0.url != excluding.url && $0.root[key] != nil && order.contains($0.scope) }
            .filter { $0.project == nil || $0.project == excluding.project }
            .min { order.firstIndex(of: $0.scope)! < order.firstIndex(of: $1.scope)! }
    }

    static func mutate(_ url: URL, expectedModified: Date??, home: URL, _ change: (inout JSON) -> Void) throws -> Backup.Record? {
        // .some(nil) means "expected no file": one appearing since is a change on disk.
        if case .some(.none) = expectedModified, exists(url) { throw WriteError.changedOnDisk(url) }
        let now = Date()
        return try ConfigWriter.mutateJSON(url, home: home, expectedModified: expectedModified ?? nil, change)
            .map { Backup.Record(original: url, copy: $0, date: now, removed: false) }
    }
}
