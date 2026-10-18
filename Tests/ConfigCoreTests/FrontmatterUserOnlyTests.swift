@testable import ConfigCore
import Testing

struct FrontmatterUserOnlyTests {
    let k = "disable-model-invocation"

    @Test func addsKey() {
        #expect(frontmatterSetting("---\nname: a\n---\nBody\n", key: k, value: "true") == "---\nname: a\ndisable-model-invocation: true\n---\nBody\n")
    }
    @Test func flipsExistingKey() {
        #expect(frontmatterSetting("---\nname: a\ndisable-model-invocation: false\n---\n", key: k, value: "true") == "---\nname: a\ndisable-model-invocation: true\n---\n")
    }
    @Test func noFrontmatter() {
        #expect(frontmatterSetting("# Title\n", key: k, value: "true") == "---\ndisable-model-invocation: true\n---\n# Title\n")
    }
    @Test func crlf() {
        #expect(frontmatterSetting("---\r\nname: a\r\n---\r\nBody\r\n", key: k, value: "true") == "---\r\nname: a\r\ndisable-model-invocation: true\r\n---\r\nBody\r\n")
        #expect(frontmatterSetting("---\r\ndisable-model-invocation: false\r\n---\r\n", key: k, value: "true") == "---\r\ndisable-model-invocation: true\r\n---\r\n")
        #expect(frontmatterSetting("Body\r\n", key: k, value: "true") == "---\r\ndisable-model-invocation: true\r\n---\r\nBody\r\n")
    }
    @Test func preservesOtherKeys() {
        let src = "---\nname: a\ndescription: \"x: y\"\nallowed-tools: Bash, Read\nmetadata:\n  v: 1\n---\nBody\n"
        let out = frontmatterSetting(src, key: k, value: "true")
        #expect(out == src.replacingOccurrences(of: "  v: 1\n---", with: "  v: 1\ndisable-model-invocation: true\n---"))
    }

    @Test func duplicateAndQuotedKeysCollapseToOne() {
        let t = "---\nname: a\ndisable-model-invocation: true\n\"disable-model-invocation\": false\ndisable-model-invocation : false\n  ---\n---\n"
        #expect(frontmatterSetting(t, key: k, value: "true") == "---\nname: a\ndisable-model-invocation: true\n  ---\n---\n")
    }
}
