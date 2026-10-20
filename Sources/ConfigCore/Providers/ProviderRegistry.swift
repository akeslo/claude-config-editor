import Foundation

public enum ProviderRegistry {
    public static let all: [any Provider] = [ClaudeProvider(), CodexProvider(), GeminiProvider(), CursorProvider(), OpenCodeProvider()]
    public static func detected(home: URL, env: [String: String], providers: [any Provider] = all) -> [(any Provider, Detection)] {
        providers.map { ($0, $0.detect(home: home, env: env)) }.filter { $0.1.installed }
    }
}
