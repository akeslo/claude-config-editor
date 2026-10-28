import SwiftUI
import ConfigCore

/// Colours for JSON values, shared by the tree and the raw-JSON block. Built on the Ledger palette.
enum JSONInk {
    static let key = Ink.accent
    static let string = Ink.success
    static let number = Ink.local
    static let bool = Ink.plugin
    static let null = Color.secondary
    static let punctuation = Color.secondary

    static func color(_ t: JSONSyntax.Token) -> Color {
        switch t {
        case .key: key
        case .string: string
        case .number: number
        case .bool: bool
        case .null: null
        case .punctuation: punctuation
        }
    }

    static func color(_ k: SettingsOutline.Kind) -> Color {
        switch k {
        case .string: string
        case .number: number
        case .bool: bool
        case .null: null
        case .text, .object, .array: .primary
        }
    }
}

/// Read-only, syntax-coloured JSON.
struct JSONText: View {
    let source: String

    var body: some View {
        Text(Self.attributed(source)).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
    }

    static func attributed(_ s: String) -> AttributedString {
        JSONSyntax.runs(s).reduce(into: AttributedString()) { out, run in
            var a = AttributedString(run.text)
            a.foregroundColor = JSONInk.color(run.token)
            out += a
        }
    }
}
