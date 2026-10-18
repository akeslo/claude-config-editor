import XCTest
@testable import ConfigCore

final class SettingsEditTests: XCTestCase {
    var home: URL!
    var file: URL { home.appending(path: ".claude/settings.json") }

    override func setUp() {
        home = FileManager.default.temporaryDirectory.appending(path: "se-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: home.appending(path: ".claude"), withIntermediateDirectories: true)
        try! Data(#"{"model":"opus","unknownThing":{"a":1},"permissions":{"allow":["Bash(ls)"],"deny":[]}}"#.utf8).write(to: file)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: home) }

    func testSetResetKeepsUnknownKeysAndUndoes() throws {
        let rec = try SettingsEdit.setKey(file, path: ["model"], value: "sonnet", home: home)
        XCTAssertEqual(readJSON(file)?["model"] as? String, "sonnet")
        XCTAssertNotNil(readJSON(file)?["unknownThing"])
        _ = try SettingsEdit.setKey(file, path: ["model"], value: nil, home: home)
        XCTAssertNil(readJSON(file)?["model"])
        try Backup.restore(XCTUnwrap(rec))
        XCTAssertEqual(readJSON(file)?["model"] as? String, "opus")
    }

    func testNestedRemoveDropsEmptyParent() throws {
        _ = try SettingsEdit.setKey(file, path: ["env", "X"], value: "1", home: home)
        XCTAssertEqual((readJSON(file)?["env"] as? JSON)?["X"] as? String, "1")
        _ = try SettingsEdit.setKey(file, path: ["env", "X"], value: nil, home: home)
        XCTAssertNil(readJSON(file)?["env"])
    }

    func testRefusesWhenChangedOnDisk() {
        XCTAssertThrowsError(try SettingsEdit.setKey(file, path: ["model"], value: "x", expectedModified: .some(Date.distantPast), home: home))
    }

    func testRuleAddEditMoveDelete() throws {
        try SettingsEdit.editRule(file, add: ("ask", "Bash(rm *)"), home: home)
        try SettingsEdit.editRule(file, remove: ("allow", "Bash(ls)"), add: ("allow", "Bash(ls *)"), home: home)
        try SettingsEdit.editRule(file, remove: ("ask", "Bash(rm *)"), add: ("deny", "Bash(rm *)"), home: home)
        let p = readJSON(file)?["permissions"] as? JSON
        XCTAssertEqual(p?["allow"] as? [String], ["Bash(ls *)"])
        XCTAssertEqual(p?["ask"] as? [String], [])
        XCTAssertEqual(p?["deny"] as? [String], ["Bash(rm *)"])
        try SettingsEdit.editRule(file, remove: ("deny", "Bash(rm *)"), home: home)
        XCTAssertEqual((readJSON(file)?["permissions"] as? JSON)?["deny"] as? [String], [])
    }

    func testParseAndFallback() {
        XCTAssertEqual(SettingsEdit.parse("true") as? Bool, true)
        XCTAssertEqual(SettingsEdit.parse("7") as? Int, 7)
        XCTAssertEqual(SettingsEdit.parse("opus") as? String, "opus")
        XCTAssertEqual((SettingsEdit.parse(#"{"a":1}"#) as? JSON)?["a"] as? Int, 1)
        let u = SettingsSource(scope: .user, url: URL(filePath: "/u"), project: nil, root: ["model": "a"], modified: nil)
        let p = SettingsSource(scope: .project, url: URL(filePath: "/p"), project: "/x", root: ["model": "b"], modified: nil)
        let l = SettingsSource(scope: .local, url: URL(filePath: "/l"), project: "/x", root: ["model": "c"], modified: nil)
        XCTAssertEqual(SettingsEdit.fallback(for: "model", excluding: l, in: [u, p, l])?.url, p.url)
        XCTAssertEqual(SettingsEdit.fallback(for: "model", excluding: p, in: [u, p])?.url, u.url)
        XCTAssertNil(SettingsEdit.fallback(for: "model", excluding: u, in: [u, p]))
    }
}
