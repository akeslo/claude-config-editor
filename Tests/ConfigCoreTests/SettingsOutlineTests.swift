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
        let nodes = SettingsOutline.tree(key: "hooks", value: hooks)!
        XCTAssertEqual(nodes, [
            .branch(title: "Notification (1)", children: [.leaf(label: nil, value: "./notify.sh")]),
            .branch(title: "PostToolUse (1)", children: [.leaf(label: nil, value: "Bash — ./lint.sh  (60s, async)")]),
        ])
        XCTAssertEqual(SettingsOutline.summary(key: "hooks", value: hooks), "2 groups · 2 hooks")
    }

    func testPermissionsGroupedByKind() {
        let perms: [String: Any] = ["allow": ["Bash(ls)", "Read(./**)"], "deny": ["Bash(rm *)"]]
        let nodes = SettingsOutline.tree(key: "permissions", value: perms)!
        XCTAssertEqual(nodes.map { if case let .branch(t, _, _) = $0 { return t } else { return "" } }, ["allow (2)", "deny (1)"])
        XCTAssertEqual(SettingsOutline.summary(key: "permissions", value: perms), "2 groups · 3 rules")
    }

    func testEnabledPluginsShowEnabledState() {
        let nodes = SettingsOutline.tree(key: "enabledPlugins", value: ["a@m": true, "b@m": false])!
        XCTAssertEqual(nodes, [.branch(title: "entries (2)", children: [.leaf(label: nil, value: "a@m — enabled"), .leaf(label: nil, value: "b@m — disabled")])])
    }

    func testScalarHasNoOutline() {
        XCTAssertNil(SettingsOutline.tree(key: "model", value: "opus"))
        XCTAssertNil(SettingsOutline.summary(key: "model", value: "opus"))
    }

    /// An unknown key with a nested object whose values are arrays of long strings becomes a tree, never raw text.
    func testGenericUnknownKeyNestedObjectOfArraysBecomesTree() {
        let autoMode: [String: Any] = [
            "allow": ["Bash(a very long command string that would otherwise wrap into an unreadable single run-on line in the cell)"],
            "environment": ["### Org-wide", "**Organization**: None configured", "**Policy**: default"],
        ]
        let nodes = SettingsOutline.tree(key: "autoMode", value: autoMode)!
        // Top level: one branch per key, sorted; each nested array is itself a branch of leaves.
        guard case let .branch(allowTitle, allowKids, .array) = nodes[0],
              case let .branch(envTitle, envKids, .array) = nodes[1] else { return XCTFail("expected two branches") }
        XCTAssertEqual(allowTitle, "allow (1 item)")
        XCTAssertEqual(envTitle, "environment (3 items)")
        XCTAssertEqual(allowKids.count, 1)
        XCTAssertEqual(envKids, [.leaf(label: nil, value: "### Org-wide", kind: .string), .leaf(label: nil, value: "**Organization**: None configured", kind: .string), .leaf(label: nil, value: "**Policy**: default", kind: .string)])
        // Scalars inside objects keep their key as a label.
        let scalars: [String: Any] = ["count": 3, "name": "x"]
        XCTAssertEqual(SettingsOutline.tree(key: "misc", value: scalars)!,
                       [.leaf(label: "count", value: "3", kind: .number), .leaf(label: "name", value: "x", kind: .string)])
        // Booleans and null keep their JSON type for colouring.
        XCTAssertEqual(SettingsOutline.tree(key: "misc", value: ["on": true, "off": NSNull()] as [String: Any])!,
                       [.leaf(label: "off", value: "null", kind: .null), .leaf(label: "on", value: "true", kind: .bool)])
    }
}
