import Foundation
import Testing
@testable import ConfigCore

/// First run used to read as a failure: an empty catalog on a fresh profile showed "Couldn't load…".
@Suite struct FirstRunStatusTests {
    /// A throwaway fixture home (same layout CLAUDE_CONFIG_EDITOR_HOME points at); never the real ~/.claude.
    func fixtureHome(_ files: [String: String] = [:]) throws -> URL {
        let home = FileManager.default.temporaryDirectory.appending(path: "first-run-\(UUID().uuidString)", directoryHint: .isDirectory)
        for (path, text) in files {
            let f = home.appending(path: path)
            try FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: f, atomically: true, encoding: .utf8)
        }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        #expect(home.path != FileManager.default.homeDirectoryForCurrentUser.path)
        return home
    }

    @Test func freshProfileIsNotSetUpNotDisconnected() throws {
        let claude = try fixtureHome().appending(path: ".claude")
        #expect(!CatalogStatus.marketplacesSetUp(claudeDir: claude))
        #expect(!CatalogStatus.communityCached(claudeDir: claude))
        let s = CatalogStatus.resolve(loading: false, rows: 0, setUp: false, wasConnected: false)
        #expect(s == .notSetUp)
        #expect(!s.isWarning)
    }

    @Test func emptyAfterSuccessfulConnectionIsDisconnected() {
        let s = CatalogStatus.resolve(loading: false, rows: 0, setUp: false, wasConnected: true)
        #expect(s == .disconnected)
        #expect(s.isWarning)
    }

    @Test func emptyAfterSetupIsDisconnected() throws {
        let claude = try fixtureHome([".claude/plugins/known_marketplaces.json": #"{"official":{"source":{"repo":"a/b"}}}"#,
                                      ".claude/config-editor-community/awesome": "x"]).appending(path: ".claude")
        #expect(CatalogStatus.marketplacesSetUp(claudeDir: claude))
        #expect(CatalogStatus.communityCached(claudeDir: claude))
        #expect(CatalogStatus.resolve(loading: false, rows: 0, setUp: true, wasConnected: false) == .disconnected)
    }

    @Test func connectingNeverWarns() {
        for setUp in [false, true] { for was in [false, true] { for rows in [0, 3] {
            let s = CatalogStatus.resolve(loading: true, rows: rows, setUp: setUp, wasConnected: was)
            #expect(s == .connecting)
            #expect(!s.isWarning)
        } } }
    }

    @Test func rowsMeanConnected() {
        #expect(CatalogStatus.resolve(loading: false, rows: 2, setUp: false, wasConnected: false) == .connected)
    }

    @Test func emptyMarketplaceFileIsNotSetUp() throws {
        let claude = try fixtureHome([".claude/plugins/known_marketplaces.json": "{}"]).appending(path: ".claude")
        #expect(!CatalogStatus.marketplacesSetUp(claudeDir: claude))
    }

    /// Run with CLAUDE_CONFIG_EDITOR_HOME=<empty dir>: the app's own paths must read as not set up.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CLAUDE_CONFIG_EDITOR_HOME"] != nil
                   && !FileManager.default.fileExists(atPath: Paths.claudeDir.path)))
    func fixtureEnvHomeIsNotSetUp() {
        #expect(!CatalogStatus.marketplacesSetUp())
        #expect(!CatalogStatus.communityCached())
    }
}
