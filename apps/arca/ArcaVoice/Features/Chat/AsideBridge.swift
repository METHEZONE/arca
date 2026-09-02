#if os(macOS)
import Foundation

/// Runs a browser task through the Aside CLI (`aside exec "<task>"`), which
/// drives the user's own logged-in Aside browser, streaming its progress.
/// Falls back to the Codex bridge when Aside isn't installed.
enum AsideBridge {
    static func asidePath() -> String? {
        let candidates = [
            "\(NSHomeDirectory())/.local/bin/aside",
            "/opt/homebrew/bin/aside",
            "/usr/local/bin/aside",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static var isAvailable: Bool { asidePath() != nil }

    /// Streams stdout/stderr lines until the process exits.
    static func run(task: String) -> AsyncStream<String> {
        AsyncStream { continuation in
            guard let path = asidePath() else {
                continuation.yield("aside CLI not found")
                continuation.finish()
                return
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = ["exec", "--effort", "medium", task]
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = "\(NSHomeDirectory())/.local/bin:/opt/homebrew/bin:/usr/local/bin:" + (environment["PATH"] ?? "/usr/bin:/bin")
            process.environment = environment
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
                for line in chunk.split(separator: "\n", omittingEmptySubsequences: true) {
                    continuation.yield(String(line))
                }
            }
            process.terminationHandler = { _ in
                pipe.fileHandleForReading.readabilityHandler = nil
                continuation.finish()
            }
            do {
                try process.run()
            } catch {
                continuation.yield("aside failed to start: \(error.localizedDescription)")
                continuation.finish()
            }
            continuation.onTermination = { _ in
                if process.isRunning { process.terminate() }
            }
        }
    }
}
#endif
