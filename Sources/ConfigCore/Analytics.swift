import Foundation

/// One session's numbers, read from its transcript (.jsonl).
public struct SessionStats: Codable, Identifiable, Sendable {
    public var id: String
    public var file: String
    public var project: String
    public var title: String?
    public var start: Date?
    public var end: Date?
    public var models: [String: Int] = [:]
    public var requests = 0
    public var inputTokens = 0
    public var cacheReadTokens = 0
    public var cacheWriteTokens = 0
    public var outputTokens = 0
    /// Largest context sent in one request (input + cache read + cache write).
    public var peakContext = 0
    public var compactions = 0
    public var tokensDroppedByCompaction = 0
    public var tools: [String: Int] = [:]
    public var userPrompts = 0

    public var totalTokens: Int { inputTokens + cacheReadTokens + cacheWriteTokens + outputTokens }
    public var duration: TimeInterval { (end ?? .distantPast).timeIntervalSince(start ?? .distantPast) }
    public var mainModel: String { models.max { $0.value < $1.value }?.key ?? "?" }
}

public struct AnalyticsReport: Sendable {
    public var sessions: [SessionStats] = []

    public init(sessions: [SessionStats] = []) { self.sessions = sessions }

    public var totalTokens: Int { sessions.reduce(0) { $0 + $1.totalTokens } }
    public var compactions: Int { sessions.reduce(0) { $0 + $1.compactions } }
    /// Share of input served from the prompt cache.
    public var cacheHitRate: Double {
        let read = sessions.reduce(0) { $0 + $1.cacheReadTokens }
        let all = sessions.reduce(0) { $0 + $1.cacheReadTokens + $1.cacheWriteTokens + $1.inputTokens }
        return all == 0 ? 0 : Double(read) / Double(all)
    }

    public func perDay(days: Int = 60) -> [(day: Date, sessions: Int, tokens: Int)] {
        let cal = Calendar.current
        let cutoff = cal.date(byAdding: .day, value: -days, to: cal.startOfDay(for: Date()))!
        let grouped = Dictionary(grouping: sessions.filter { ($0.start ?? .distantPast) >= cutoff }) { cal.startOfDay(for: $0.start!) }
        return grouped.map { ($0.key, $0.value.count, $0.value.reduce(0) { $0 + $1.totalTokens }) }.sorted { $0.day < $1.day }
    }

    public func topTools(_ n: Int = 15) -> [(name: String, count: Int)] {
        var all: [String: Int] = [:]
        for s in sessions { all.merge(s.tools, uniquingKeysWith: +) }
        return all.sorted { $0.value > $1.value }.prefix(n).map { ($0.key, $0.value) }
    }

    public func modelMix() -> [(model: String, requests: Int)] {
        var all: [String: Int] = [:]
        for s in sessions { all.merge(s.models, uniquingKeysWith: +) }
        return all.sorted { $0.value > $1.value }.map { ($0.key, $0.value) }
    }
}

public enum Analytics {
    static let cacheURL: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "ClaudeConfig")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "sessions-v1.json")
    }()

    struct CacheEntry: Codable { let size: Int64; let modified: Date; let stats: SessionStats }

    /// Parses every transcript, reusing cached results for files that have not changed since last time.
    public static func load(progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }) async -> AnalyticsReport {
        await Task.detached(priority: .utility) {
            let decoder = JSONDecoder()
            var cache = (try? Data(contentsOf: cacheURL)).flatMap { try? decoder.decode([String: CacheEntry].self, from: $0) } ?? [:]
            let files = children(Paths.claudeDir.appending(path: "projects")).flatMap { children($0).filter { $0.pathExtension == "jsonl" } }
            var out: [SessionStats] = []
            for (i, f) in files.enumerated() {
                let size = fileSize(f), mod = modificationDate(f) ?? .distantPast
                let stats: SessionStats
                if let c = cache[f.path], c.size == size, c.modified == mod {
                    stats = c.stats
                } else {
                    stats = parse(f)
                    cache[f.path] = CacheEntry(size: size, modified: mod, stats: stats)
                }
                if stats.requests > 0 { out.append(stats) }
                if i % 50 == 0 { progress(i, files.count) }
            }
            let live = Set(files.map(\.path))
            cache = cache.filter { live.contains($0.key) }
            if let data = try? JSONEncoder().encode(cache) { try? data.write(to: cacheURL) }
            return AnalyticsReport(sessions: out.sorted { ($0.start ?? .distantPast) > ($1.start ?? .distantPast) })
        }.value
    }

    /// Reads one transcript line by line. Assistant messages are split into several lines per API request, so usage is counted once per request id.
    public static func parse(_ url: URL) -> SessionStats {
        var s = SessionStats(id: url.deletingPathExtension().lastPathComponent, file: url.path, project: "")
        guard let handle = try? FileHandle(forReadingFrom: url) else { return s }
        defer { try? handle.close() }
        var seenRequests = Set<String>()
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var buffer = Data()

        func process(_ line: Data) {
            guard let d = (try? JSONSerialization.jsonObject(with: line)) as? JSON else { return }
            let type = d["type"] as? String
            if let ts = (d["timestamp"] as? String).flatMap(iso.date) {
                if s.start == nil || ts < s.start! { s.start = ts }
                if s.end == nil || ts > s.end! { s.end = ts }
            }
            if s.project.isEmpty, let cwd = d["cwd"] as? String { s.project = cwd }
            switch type {
            case "ai-title":
                s.title = d["aiTitle"] as? String ?? d["title"] as? String ?? s.title
            case "user":
                if (d["message"] as? JSON)?["content"] is String, d["isMeta"] as? Bool != true { s.userPrompts += 1 }
            case "system" where d["subtype"] as? String == "compact_boundary":
                s.compactions += 1
                s.tokensDroppedByCompaction += ((d["compactMetadata"] as? JSON)?["preTokens"] as? Int ?? 0) - ((d["compactMetadata"] as? JSON)?["postTokens"] as? Int ?? 0)
            case "assistant":
                guard d["isSidechain"] as? Bool != true, let m = d["message"] as? JSON else { return }
                for c in m["content"] as? [JSON] ?? [] where c["type"] as? String == "tool_use" {
                    if let name = c["name"] as? String { s.tools[name, default: 0] += 1 }
                }
                let rid = d["requestId"] as? String ?? m["id"] as? String ?? UUID().uuidString
                guard seenRequests.insert(rid).inserted, let u = m["usage"] as? JSON else { return }
                let input = u["input_tokens"] as? Int ?? 0, read = u["cache_read_input_tokens"] as? Int ?? 0
                let write = u["cache_creation_input_tokens"] as? Int ?? 0
                s.requests += 1
                s.inputTokens += input
                s.cacheReadTokens += read
                s.cacheWriteTokens += write
                s.outputTokens += u["output_tokens"] as? Int ?? 0
                s.peakContext = max(s.peakContext, input + read + write)
                if let model = m["model"] as? String, !model.hasPrefix("<") { s.models[model, default: 0] += 1 }
            default: break
            }
        }

        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            buffer.append(chunk)
            while let nl = buffer.firstIndex(of: 0x0A) {
                process(buffer[buffer.startIndex..<nl])
                buffer.removeSubrange(buffer.startIndex...nl)
            }
        }
        if !buffer.isEmpty { process(buffer) }
        return s
    }
}
