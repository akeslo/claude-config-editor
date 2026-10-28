import XCTest
@testable import ConfigCore

final class SettingsOutlineTests: XCTestCase {
    func testHooksGroupedByEventWithMatcherAndTimeout() {
        let hooks: [String: Any] = [
            "PostToolUse": [
                ["matcher": "Bash", "hooks": [["type": "command", "command": "./lint.sh", "timeout": 60, "async": true]]],
            ],
            "Notification": [
                ["hooks": [["type": "command", "command": "./notify.sh"]]],
            ],
        ]
        let secs = SettingsOutline.sections(key: "hooks", value: hooks)!
        // Sorted by event name: Notification, PostToolUse.
        XCTAssertEqual(secs.map(\.title), ["Notification (1)", "PostToolUse (1)"])
        XCTAssertEqual(secs[1].rows, ["Bash — ./lint.sh  (60s, async)"])
        XCTAssertEqual(secs[0].rows, ["./notify.sh"])
        XCTAssertEqual(SettingsOutline.summary(key: "hooks", value: hooks), "2 groups · 2 hooks")
    }

    func testPermissionsGroupedByKind() {
        let perms: [String: Any] = ["allow": ["Bash(ls)", "Read(./**)"], "deny": ["Bash(rm *)"]]
        let secs = SettingsOutline.sections(key: "permissions", value: perms)!
        XCTAssertEqual(secs.map(\.title), ["allow (2)", "deny (1)"])
        XCTAssertEqual(secs[0].rows, ["Bash(ls)", "Read(./**)"])
        XCTAssertEqual(SettingsOutline.summary(key: "permissions", value: perms), "2 groups · 3 rules")
    }

    func testEnabledPluginsShowEnabledState() {
        let secs = SettingsOutline.sections(key: "enabledPlugins", value: ["a@m": true, "b@m": false])!
        XCTAssertEqual(secs.count, 1)
        XCTAssertEqual(secs[0].rows, ["a@m — enabled", "b@m — disabled"])
    }

    func testScalarHasNoOutline() {
        XCTAssertNil(SettingsOutline.sections(key: "model", value: "opus"))
        XCTAssertNil(SettingsOutline.summary(key: "model", value: "opus"))
    }
}
