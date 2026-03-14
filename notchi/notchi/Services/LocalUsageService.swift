import Foundation

struct CodexUsageSnapshot {
    let usagePercentage: Int?
    let resetDate: Date?
    let inputTokens: Int
    let outputTokens: Int
    let totalTokens: Int
    let contextWindow: Int?

    var effectivePercentage: Int? {
        if let usagePercentage { return usagePercentage }
        guard let contextWindow, contextWindow > 0 else { return nil }
        let ratio = Double(totalTokens) / Double(contextWindow)
        return Int((min(max(ratio, 0), 1) * 100).rounded())
    }

    var formattedResetTime: String? {
        guard let resetDate else { return nil }
        let now = Date()
        guard resetDate > now else { return nil }

        let interval = Int(resetDate.timeIntervalSince(now))
        let hours = interval / 3600
        let minutes = (interval % 3600) / 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }
}

struct GeminiUsageSnapshot {
    let inputTokens: Int
    let outputTokens: Int
    let cachedTokens: Int
    let totalTokens: Int
}

@MainActor
@Observable
final class LocalUsageService {
    static let shared = LocalUsageService()

    var codexUsage: CodexUsageSnapshot?
    var geminiUsage: GeminiUsageSnapshot?
    var isLoading = false

    private init() {}

    func refreshAll() async {
        isLoading = true

        async let codexTask = Task.detached(priority: .utility) {
            Self.readLatestCodexUsage()
        }.value

        async let geminiTask = Task.detached(priority: .utility) {
            Self.readLatestGeminiUsage()
        }.value

        codexUsage = await codexTask
        geminiUsage = await geminiTask
        isLoading = false
    }

    nonisolated private static func readLatestCodexUsage() -> CodexUsageSnapshot? {
        guard let path = latestCodexSessionPath() else { return nil }
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }

        let fileSize = (try? handle.seekToEnd()) ?? 0
        if fileSize == 0 { return nil }

        let tailBytes = min(fileSize, UInt64(700_000))
        if fileSize > tailBytes {
            try? handle.seek(toOffset: fileSize - tailBytes)
        } else {
            try? handle.seek(toOffset: 0)
        }

        guard let data = try? handle.readToEnd(),
              let content = String(data: data, encoding: .utf8) else {
            return nil
        }

        for line in content.split(separator: "\n").reversed() {
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  (json["type"] as? String) == "event_msg",
                  let payload = json["payload"] as? [String: Any],
                  (payload["type"] as? String) == "token_count",
                  let info = payload["info"] as? [String: Any],
                  let totalUsage = info["total_token_usage"] as? [String: Any] else {
                continue
            }

            let input = intValue(totalUsage["input_tokens"]) ?? 0
            let output = intValue(totalUsage["output_tokens"]) ?? 0
            let total = intValue(totalUsage["total_tokens"]) ?? (input + output)
            let contextWindow = intValue(info["model_context_window"])

            var percent: Int?
            var resetDate: Date?
            if let rateLimits = payload["rate_limits"] as? [String: Any],
               let primary = rateLimits["primary"] as? [String: Any] {
                if let used = doubleValue(primary["used_percent"]) {
                    percent = Int(used.rounded())
                }
                if let resetsAt = doubleValue(primary["resets_at"]) {
                    resetDate = Date(timeIntervalSince1970: resetsAt)
                }
            }

            return CodexUsageSnapshot(
                usagePercentage: percent,
                resetDate: resetDate,
                inputTokens: input,
                outputTokens: output,
                totalTokens: total,
                contextWindow: contextWindow
            )
        }

        return nil
    }

    nonisolated private static func readLatestGeminiUsage() -> GeminiUsageSnapshot? {
        guard let path = latestGeminiSessionPath(),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let messages = json["messages"] as? [[String: Any]] else {
            return nil
        }

        var input = 0
        var output = 0
        var cached = 0
        var total = 0

        for message in messages {
            let type = (message["type"] as? String)?.lowercased() ?? ""
            guard type == "gemini" || type == "assistant" || type == "model" else { continue }
            guard let tokens = message["tokens"] as? [String: Any] else { continue }

            input += intValue(tokens["input"]) ?? 0
            output += intValue(tokens["output"]) ?? 0
            cached += intValue(tokens["cached"]) ?? 0
            total += intValue(tokens["total"]) ?? 0
        }

        guard input > 0 || output > 0 || total > 0 else { return nil }
        return GeminiUsageSnapshot(
            inputTokens: input,
            outputTokens: output,
            cachedTokens: cached,
            totalTokens: total
        )
    }

    nonisolated private static func latestCodexSessionPath() -> String? {
        let root = URL(fileURLWithPath: "\(NSHomeDirectory())/.codex/sessions", isDirectory: true)
        return latestFile(
            at: root,
            recursive: true,
            matching: { $0.pathExtension == "jsonl" }
        )
    }

    nonisolated private static func latestGeminiSessionPath() -> String? {
        let root = URL(fileURLWithPath: "\(NSHomeDirectory())/.gemini/tmp", isDirectory: true)
        return latestFile(
            at: root,
            recursive: true,
            matching: { $0.pathExtension == "json" && $0.path.contains("/chats/") }
        )
    }

    nonisolated private static func latestFile(
        at root: URL,
        recursive: Bool,
        matching predicate: (URL) -> Bool
    ) -> String? {
        let fileManager = FileManager.default
        var bestPath: String?
        var bestDate = Date.distantPast

        if recursive {
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else {
                return nil
            }

            for case let fileURL as URL in enumerator where predicate(fileURL) {
                let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
                if values?.isRegularFile == false { continue }

                let modified = values?.contentModificationDate ?? Date.distantPast
                if bestPath == nil || modified > bestDate {
                    bestPath = fileURL.path
                    bestDate = modified
                }
            }
            return bestPath
        }

        guard let urls = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        for fileURL in urls where predicate(fileURL) {
            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
            if values?.isRegularFile == false { continue }

            let modified = values?.contentModificationDate ?? Date.distantPast
            if bestPath == nil || modified > bestDate {
                bestPath = fileURL.path
                bestDate = modified
            }
        }
        return bestPath
    }

    nonisolated private static func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let double = value as? Double { return Int(double.rounded()) }
        if let number = value as? NSNumber { return number.intValue }
        if let text = value as? String, let int = Int(text) { return int }
        return nil
    }

    nonisolated private static func doubleValue(_ value: Any?) -> Double? {
        if let double = value as? Double { return double }
        if let int = value as? Int { return Double(int) }
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String, let double = Double(text) { return double }
        return nil
    }
}
