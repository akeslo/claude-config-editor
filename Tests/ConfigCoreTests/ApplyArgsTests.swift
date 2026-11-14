import Testing
@testable import ConfigCore

@Suite struct ApplyArgsTests {
    @Test func mcpRemoveScopeBounds() {
        #expect(Apply.mcpRemoveScope(["mcp", "remove", "x", "-s"]) == "local")
        #expect(Apply.mcpRemoveScope(["mcp", "remove", "x", "-s", "user"]) == "user")
        #expect(Apply.mcpRemoveScope(["mcp", "remove", "x"]) == "local")
    }
}
