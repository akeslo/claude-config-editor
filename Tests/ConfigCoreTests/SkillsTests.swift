import Foundation
import Testing
@testable import ConfigCore

struct SkillsTests {
    func skill(_ name: String, _ scope: Scope, owner: String? = nil, desc: String = "x", uses: Int = 0) -> Component {
        var c = Component(kind: .skill, name: name, scope: scope, owner: owner, file: URL(filePath: "/tmp/\(scope.rawValue)/\(owner ?? "")/\(name)/SKILL.md"),
                          description: desc, lineCount: 1, alwaysLoaded: true, frontmatterKeys: [])
        c.usageCount = uses
        return c
    }

}
