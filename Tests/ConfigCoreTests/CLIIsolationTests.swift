import Foundation
import CryptoKit
import Testing
@testable import ConfigCore

/// The suite once wrote fixture project rows into the real ~/.claude/plugins/installed_plugins.json.
@Suite struct CLIIsolationTests {
    let registry = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/plugins/installed_plugins.json")

    func fingerprint() -> String? {
        guard let d = try? Data(contentsOf: registry) else { return nil }
        let m = (try? FileManager.default.attributesOfItem(atPath: registry.path)[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return SHA256.hash(data: d).description + "@\(m)"
    }

    // Never spawn a real mutating CLI here: if the guard regressed, the test itself would pollute.
    @Test func pluginCLIUnderTestsCannotTouchRealRegistry() async {
        let before = fingerprint()
        try? #require(ClaudeCLI.isUnderTests)
        let real = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude")
        #expect(ClaudeCLI.childEnvironment([:], realClaudeDir: real) == nil || Paths.claudeDir != real)
        #expect(ClaudeCLI.childEnvironment(["CLAUDE_CONFIG_DIR": real.path], realClaudeDir: real) == nil || Paths.claudeDir != real)
        if ClaudeCLI.childEnvironment([:], realClaudeDir: real) == nil {
            let r = await ClaudeCLI.run(["plugin", "list"])  // read-only even if the guard ever failed
            #expect(r.output.hasPrefix("Refused"))
        }
        #expect(fingerprint() == before)
    }

    @Test func fixtureConfigDirIsAllowed() {
        let fake = URL(filePath: "/nonexistent-real/.claude")
        #expect(ClaudeCLI.childEnvironment(["CLAUDE_CONFIG_DIR": "/tmp/fixture/.claude"], realClaudeDir: fake) != nil)
        let real = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude")
        if Paths.claudeDir == real { #expect(ClaudeCLI.childEnvironment([:], realClaudeDir: real) == nil) }
    }
}
