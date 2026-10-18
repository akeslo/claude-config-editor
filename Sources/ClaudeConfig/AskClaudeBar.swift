import SwiftUI
import ConfigCore

/// One question about the current screen, one answer; a new question replaces it. Cleared by `.id(section)` at the call site.
struct AskClaudeBar: View {
    @Environment(AppModel.self) private var model
    let section: AppSection
    @State private var question = ""
    @State private var answer: String?
    @State private var failed = false
    @State private var asking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("Ask Claude about this screen…", text: $question)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(submit)
                if asking { ProgressView().controlSize(.small) }
                Button("Ask", action: submit)
                    .disabled(asking || question.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if failed {
                Text("Claude didn't answer. Is the `claude` command installed?").font(.caption).foregroundStyle(.secondary)
            } else if let answer {
                Text(answer).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                Text("AI suggestion — not verified").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private func submit() {
        let q = question.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, !asking else { return }
        asking = true; answer = nil; failed = false
        Task {
            let a = await model.ask(q, about: section)
            asking = false
            answer = a; failed = a == nil
        }
    }
}
