import Foundation

/// Local-only metering for BYOK calls made by ARCA.
///
/// Provider billing/quota remains authoritative, but this gives the notch
/// dashboard a truthful seven-day view of calls that passed through the app.
public enum AIUsageLog {
    public static let fileName = "ai-usage.jsonl"

    public static func recordResponse(provider: String, model: String, source: String, data: Data) {
        guard let usage = tokenUsage(from: data), usage.total > 0 else { return }
        append(provider: provider, model: model, source: source, inputTokens: usage.input, outputTokens: usage.output)
    }

    public static func append(provider: String, model: String, source: String, inputTokens: Int, outputTokens: Int) {
        let record: [String: Any] = [
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "provider": provider,
            "model": model,
            "source": source,
            "inputTokens": inputTokens,
            "outputTokens": outputTokens,
            "totalTokens": inputTokens + outputTokens,
        ]
        guard JSONSerialization.isValidJSONObject(record),
              let data = try? JSONSerialization.data(withJSONObject: record),
              let line = String(data: data, encoding: .utf8)
        else { return }

        let url = logURL()
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if !FileManager.default.fileExists(atPath: url.path) {
            try? Data().write(to: url)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: Data((line + "\n").utf8))
        } catch {
            return
        }
    }

    public static func logURL() -> URL {
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return applicationSupport
            .appendingPathComponent("ARCA", isDirectory: true)
            .appendingPathComponent(fileName)
    }

    private static func tokenUsage(from data: Data) -> (input: Int, output: Int, total: Int)? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let usage = root["usage"] as? [String: Any]
        else { return nil }

        let input = (usage["input_tokens"] as? Int ?? 0)
            + (usage["cache_creation_input_tokens"] as? Int ?? 0)
            + (usage["cache_read_input_tokens"] as? Int ?? 0)
            + (usage["cached_input_tokens"] as? Int ?? 0)
        let output = usage["output_tokens"] as? Int ?? 0
        let total = usage["total_tokens"] as? Int ?? input + output
        return (input, output, total)
    }
}
