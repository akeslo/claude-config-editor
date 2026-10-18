import Foundation

/// Key-level edits to settings files with an undoable `Backup` snapshot. Unknown keys are always kept.
public enum SettingsEdit {
    /// Sets (or with `nil` removes) one key path. Refuses if the file changed since `expectedModified` (pass the scan's date).
    /// Returns the pre-write snapshot, nil when the file did not exist yet.
    @discardableResult
    public static func setKey(_ url: URL, path: [String], value: Any?, expectedModified: Date?? = nil, home: URL = Paths.home) throws -> Backup.Record? {
        try mutate(url, expectedModified: expectedModified, home: home) { root in
            func set(_ dict: inout JSON, _ keys: ArraySlice<String>) {
                guard let key = keys.first else { return }
                if keys.count == 1 { dict[key] = value; return }
                var child = dict[key] as? JSON ?? [:]
                set(&child, keys.dropFirst())
                dict[key] = child.isEmpty && value == nil ? nil : child
            }
            set(&root, path[...])
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
        let current = modificationDate(url)
        if let expected = expectedModified, exists(url), current != expected { throw SafeWriteError.changedOnDisk }
        if exists(url), readJSON(url) == nil { throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: url.path]) }
        var root = readJSON(url) ?? [:]
        change(&root)
        let record = exists(url) ? try Backup.snapshot(url, home: home) : nil
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmp = url.deletingLastPathComponent().appending(path: ".\(url.lastPathComponent).tmp")
        FileManager.default.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600])
        if exists(url) { _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp) } else { try FileManager.default.moveItem(at: tmp, to: url) }
        return record
    }
}
