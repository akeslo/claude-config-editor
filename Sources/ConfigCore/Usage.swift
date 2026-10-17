import Foundation

/// One day × agent × model of token use and cost, as reported by ccusage.
public struct UsageRow: Sendable, Identifiable, Hashable {
    public var id: String { "\(day)|\(agent)|\(model)" }
    public let day: String  // YYYY-MM-DD in the local time zone, as ccusage groups it
    public let agent: String
    public let model: String
    public let input, output, cacheCreate, cacheRead: Int
    public let cost: Double
    public var tokens: Int { input + output + cacheCreate + cacheRead }
}

public struct UsageReport: Sendable {
    public let rows: [UsageRow]
    public var agents: [String] { Array(Set(rows.map(\.agent))).sorted() }

    /// Rows from the last `days` days, today included (`nil` = all time).
    public func rows(lastDays days: Int?, agent: String? = nil, today: Date = Date()) -> [UsageRow] {
        let cutoff = days.map { UsageReport.dayString(Calendar.current.date(byAdding: .day, value: 1 - $0, to: today)!) }
        return rows.filter { (cutoff == nil || $0.day >= cutoff!) && (agent == nil || $0.agent == agent) }
    }

    public static func dayString(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    /// Decodes `ccusage daily --json --by-agent`.
    public static func decode(_ data: Data) throws -> UsageReport {
        struct Model: Decodable { let modelName: String; let inputTokens, outputTokens, cacheCreationTokens, cacheReadTokens: Int; let cost: Double }
        struct Agent: Decodable { let agent: String; let modelBreakdowns: [Model] }
        struct Day: Decodable { let period: String; let agent: String?; let agents: [Agent]?; let modelBreakdowns: [Model] }
        struct Root: Decodable { let daily: [Day] }
        let root = try JSONDecoder().decode(Root.self, from: data)
        return UsageReport(rows: root.daily.flatMap { d in
            (d.agents ?? [Agent(agent: d.agent ?? "claude", modelBreakdowns: d.modelBreakdowns)]).flatMap { a in
                a.modelBreakdowns.map {
                    UsageRow(day: d.period, agent: a.agent, model: $0.modelName, input: $0.inputTokens, output: $0.outputTokens,
                             cacheCreate: $0.cacheCreationTokens, cacheRead: $0.cacheReadTokens, cost: $0.cost)
                }
            }
        })
    }
}

public enum CCUsage {
    /// Runs ccusage through the login shell, since GUI apps don't inherit the user's PATH (nvm, Homebrew, …).
    public static func load(timeout: TimeInterval = 120) async -> Result<UsageReport, UsageError> {
        await Task.detached {
            let p = Process()
            p.executableURL = URL(filePath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
            p.arguments = ["-lc", "command -v npx >/dev/null || exit 127; NO_COLOR=1 npx -y ccusage@latest daily --json --by-agent"]
            p.currentDirectoryURL = Paths.home
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            p.standardInput = FileHandle.nullDevice
            do { try p.run() } catch { return .failure(.failed(error.localizedDescription)) }
            let timer = DispatchWorkItem { p.terminate() }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            timer.cancel()
            if p.terminationStatus == 127 { return .failure(.noNode) }
            guard p.terminationStatus == 0, let start = data.firstIndex(of: UInt8(ascii: "{")) else {
                return .failure(.failed("ccusage exited with status \(p.terminationStatus)"))
            }
            do { return .success(try UsageReport.decode(data[start...])) } catch { return .failure(.failed(error.localizedDescription)) }
        }.value
    }
}

public enum UsageError: Error, Sendable, Equatable {
    case noNode
    case failed(String)
}
