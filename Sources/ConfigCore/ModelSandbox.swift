import Foundation

public struct AskFailure: Error, Sendable { public let reason: String }

/// Runs one model CLI call: fresh empty temp cwd holding only copies of `files`, the command's (scrubbed) env,
/// prompt on stdin, killed on timeout or task cancellation, stderr tail returned on failure.
public enum ModelSandbox {
    public static func run(_ cmd: AskCommand, prompt: String, files: [URL] = [], timeout: TimeInterval = 120) async -> Result<String, AskFailure> {
        let fm = FileManager.default
        let cwd = fm.temporaryDirectory.appending(path: "claude-config-ask-\(UUID().uuidString)")
        do { try fm.createDirectory(at: cwd, withIntermediateDirectories: true) } catch { return .failure(AskFailure(reason: error.localizedDescription)) }
        defer { try? fm.removeItem(at: cwd) }
        copy(files, into: cwd)
        let p = Process()
        p.executableURL = cmd.executable
        p.arguments = cmd.args
        p.currentDirectoryURL = cwd
        p.environment = cmd.env
        let out = Pipe(), err = Pipe(), inp = Pipe()
        p.standardOutput = out; p.standardError = err; p.standardInput = inp
        return await withTaskCancellationHandler {
            await Task.detached { wait(p, out: out, err: err, inp: inp, prompt: prompt, timeout: timeout) }.value
        } onCancel: { if p.isRunning { p.terminate() } }
    }

    /// Blocking half: start, feed stdin, drain both pipes, enforce the timeout.
    private static func wait(_ p: Process, out: Pipe, err: Pipe, inp: Pipe, prompt: String, timeout: TimeInterval) -> Result<String, AskFailure> {
                do { try p.run() } catch { return .failure(AskFailure(reason: error.localizedDescription)) }
                DispatchQueue.global().async {
                    try? inp.fileHandleForWriting.write(contentsOf: Data(prompt.utf8))
                    try? inp.fileHandleForWriting.close()
                }
                let timedOut = Flag()
                let timer = DispatchWorkItem { timedOut.set(); p.terminate() }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
                let errData = Box()
                let g = DispatchGroup()
                DispatchQueue.global().async(group: g) { errData.data = err.fileHandleForReading.readDataToEndOfFile() }
                // shortcut: terminate() signals only the CLI, not its children; a child holding the pipe delays this read. Use a process group if that shows up.
                let data = out.fileHandleForReading.readDataToEndOfFile()
                g.wait()
                p.waitUntilExit()
                timer.cancel()
                if timedOut.value { return .failure(AskFailure(reason: "timed out after \(Int(timeout))s")) }
                let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                guard p.terminationStatus == 0 else {
                    let tail = String(String(decoding: errData.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).suffix(500))
                    return .failure(AskFailure(reason: tail.isEmpty ? "exited with status \(p.terminationStatus)" : tail))
                }
                return .success(text)
    }

    /// Copies plain files flat into `dir` (numbered on name clashes); directories and credential files are refused.
    static func copy(_ files: [URL], into dir: URL) {
        let fm = FileManager.default
        var used = Set<String>()
        for f in files {
            let real = f.resolvingSymlinksInPath()
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: real.path, isDirectory: &isDir), !isDir.boolValue,
                  !isCredential(f), !isCredential(real) else { continue }
            var name = f.lastPathComponent, n = 1
            while used.contains(name) { n += 1; name = "\(n)-\(f.lastPathComponent)" }
            used.insert(name)
            try? fm.copyItem(at: real, to: dir.appending(path: name))
        }
    }

    static func isCredential(_ u: URL) -> Bool {
        let n = u.lastPathComponent.lowercased()
        return [".credentials.json", "credentials.json", "auth.json", "oauth_creds.json", ".claude.json", ".env"].contains(n)
            || ["token", "credential", "secret", "password"].contains { n.contains($0) }
            || [".key", ".pem", ".p12"].contains { n.hasSuffix($0) }
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock(); private var v = false
    func set() { lock.withLock { v = true } }
    var value: Bool { lock.withLock { v } }
}
private final class Box: @unchecked Sendable { var data = Data() }

/// A local model runner with no config tree (Ollama): shown under Models, never as a sidebar provider.
public protocol ModelBackend: Sendable {
    var id: String { get }
    func detect(home: URL, env: [String: String]) -> URL?
    func askCommand(model: String, exe: URL) -> AskCommand
}

extension ProviderRegistry {
    /// The ask for the provider whose screen is open, else Claude Code; nil when neither can ask.
    public static func askCommand(for id: ProviderID?, model: String? = nil, home: URL, env: [String: String], providers: [any Provider] = all) -> AskCommand? {
        let pick = { (p: any Provider) in p.askCommand(model: model, detection: p.detect(home: home, env: env)) }
        if let p = providers.first(where: { $0.id == id }), let c = pick(p) { return c }
        return providers.first { $0.id == .claude }.flatMap { pick($0) }
    }
}
