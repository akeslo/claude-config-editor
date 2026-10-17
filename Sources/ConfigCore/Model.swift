import Foundation

public enum Scope: String, CaseIterable, Sendable {
    case managed = "Managed", user = "User", userLocal = "User (local)", project = "Project", local = "Project (local)", plugin = "Plugin", desktop = "Claude Desktop"
}

/// JSON trees are read-only after scanning, so sharing them across tasks is safe.
public struct SettingsSource: Identifiable, @unchecked Sendable {
    public var id: String { url.path }
    public let scope: Scope
    public let url: URL
    public let project: String?
    public let root: JSON
    public let modified: Date?

    public init(scope: Scope, url: URL, project: String?, root: JSON, modified: Date?) {
        (self.scope, self.url, self.project, self.root, self.modified) = (scope, url, project, root, modified)
    }
}

public struct Project: Identifiable, Sendable {
    public var id: String { path }
    public let path: String
    public let entryBytes: Int
    public let allowedTools: [String]
    public let mcpServerNames: [String]
    public let trusted: Bool
    public let dataDir: URL
    public var transcriptCount = 0
    public var dataBytes: Int64 = 0
    public var lastSession: Date?
    public var folderExists: Bool { exists(URL(filePath: path)) }
}

public struct MCPServer: Identifiable, Sendable {
    public var id: String { "\(scope.rawValue)|\(project ?? "")|\(name)" }
    public let name: String
    public let scope: Scope
    public let project: String?
    public let source: URL
    public let command: String
    public let transport: String
    public let env: [String: String]
    public let headers: [String: String]
    public let raw: String
    /// From its plugin, or the npm package description for npx servers already in the npx cache.
    public var description = ""
}

public enum ComponentKind: String, CaseIterable, Sendable {
    case skill = "Skill", subagent = "Subagent", command = "Command", outputStyle = "Output style"
}

public struct Component: Identifiable, Sendable {
    public var id: String { file.path }
    public let kind: ComponentKind
    public let name: String
    public let scope: Scope
    public let owner: String?           // plugin id or project path
    public let file: URL
    public let description: String
    public let lineCount: Int
    public let alwaysLoaded: Bool       // false when disable-model-invocation: true
    public let frontmatterKeys: [String]
    public var usageCount = 0
    public var lastUsed: Date?
    /// skillOverrides value from user settings: "user-invocable-only" hides it from the listing, "name-only" drops the description.
    public var override: String?
    public var listingTokens: Int {
        guard alwaysLoaded, override != "user-invocable-only" else { return 0 }
        return override == "name-only" ? estimateTokens(name) + 4 : estimateTokens(name + description) + 4
    }
}

public struct Plugin: Identifiable, Sendable {
    public var id: String
    public let version: String
    public let scope: String
    public let enabled: Bool
    public let installPath: URL
    public let notes: [String]
    public var usageCount = 0
    public var lastUsed: Date?
    public var alwaysOnTokens: Int?     // from `claude plugin details`, filled in lazily
    public var repoURL: URL?            // plugin.json repository/homepage, else its marketplace's GitHub repo
    public var description = ""         // plugin.json description
    public var latestVersion: String?   // newer version in its marketplace's local copy, when there is one
    public var marketplace: String { id.split(separator: "@").last.map(String.init) ?? "" }
}

public struct AvailablePlugin: Identifiable, Sendable {
    public var id: String
    public let name: String
    public let description: String
    public let marketplace: String
    public let installCount: Int
    public let installed: Bool
    public var repoURL: URL?
}

public struct Hook: Identifiable, Sendable {
    public let id = UUID()
    public let event: String
    public let matcher: String?
    public let matcherIsValid: Bool
    public let command: String
    public let timeout: Int?
    public let async: Bool
    public let source: String
    public let sourceURL: URL
    /// Script file the command runs, when it names one we can check.
    public let scriptPath: URL?
}

public struct PermissionRule: Identifiable, Sendable {
    public let id = UUID()
    public let kind: String             // allow / deny / ask / allowedTools
    public let rule: String
    public let source: String
    public let sourceURL: URL
}

public struct InstructionFile: Identifiable, Sendable {
    public var id: String { url.path }
    public enum Kind: String, Sendable { case claudeMD = "CLAUDE.md", localMD = "CLAUDE.local.md", rule = "Rule", memoryIndex = "MEMORY.md" }
    public let kind: Kind
    public let url: URL
    public let project: String?
    public let lines: Int
    public let tokens: Int
    public let pathScoped: Bool         // rules with `paths:` frontmatter load only when matching files are touched
    public var problems: [String] = []
}

public struct StorageArea: Identifiable, Sendable {
    public enum Safety: String, Sendable { case safe = "Safe to clear", care = "Clear with care", keep = "Don't touch", unknown = "Unknown" }
    public var id: String { url.path }
    public let name: String
    public let url: URL
    public let safety: Safety
    public let term: Term
    public let autoCleaned: Bool
    public var bytes: Int64 = 0
    public var oldest: Date?
    public var itemCount = 0
}

public struct Snapshot: Sendable {
    public var claudeJSONModified: Date?
    public var claudeJSONBytes: Int64 = 0
    public var settings: [SettingsSource] = []
    public var projects: [Project] = []
    public var mcpServers: [MCPServer] = []
    public var components: [Component] = []
    public var plugins: [Plugin] = []
    public var hooks: [Hook] = []
    public var permissions: [PermissionRule] = []
    public var instructions: [InstructionFile] = []
    public var strayFiles: [URL] = []
    /// Extra installs of a plugin id already in `plugins` (another scope or version).
    public var duplicatePlugins: [Plugin] = []   // *.bak and similar leftovers in ~/.claude
    public var claudeVersion: String?
    public var cliAvailable: Bool { ClaudeCLI.executable != nil }
    public var scannedAt = Date()

    public init() {}

    public func setting(_ key: String) -> (value: Any, source: SettingsSource)? {
        // Global view, highest precedence first; project files only apply inside their project.
        let order: [Scope] = [.managed, .userLocal, .user]
        for scope in order {
            for s in settings where s.scope == scope {
                if let v = s.root[key] { return (v, s) }
            }
        }
        return nil
    }

    public var cleanupPeriodDays: Int { setting("cleanupPeriodDays")?.value as? Int ?? 30 }
}
