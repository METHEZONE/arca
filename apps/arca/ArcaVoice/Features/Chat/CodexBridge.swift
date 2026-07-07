#if os(macOS)
import Foundation

/// Delegates browser/screen tasks to the local Codex CLI (computer-use +
/// browser plugins). ARCA proposes a task; on confirmation we run
/// `codex exec` and stream its progress into the chat. Non-sandboxed macOS only.
enum CodexBridge {
    /// Common install locations for the codex binary.
    static func codexPath() -> String? {
        let candidates = [
            "\(NSHomeDirectory())/.superset/bin/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "\(NSHomeDirectory())/.npm-global/bin/codex",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static var isAvailable: Bool { codexPath() != nil }

    /// Runs a browser/computer-use task, yielding progress lines as they arrive.
    static func run(task: String) -> AsyncStream<String> {
        AsyncStream { continuation in
            guard let codex = codexPath() else {
                continuation.yield("Couldn't find the Codex CLI. (~/.superset/bin/codex)")
                continuation.finish()
                return
            }
            Thread.detachNewThread {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: codex)
                process.arguments = [
                    "exec",
                    "--dangerously-bypass-approvals-and-sandbox",
                    "-c", "use_case=chrome",
                    task,
                ]
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe

                let handle = pipe.fileHandleForReading
                do {
                    try process.run()
                } catch {
                    continuation.yield("Codex failed to start: \(error.localizedDescription)")
                    continuation.finish()
                    return
                }
                // Stream stdout line-buffered as Codex works.
                var buffer = Data()
                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break }
                    buffer.append(chunk)
                    while let newline = buffer.firstIndex(of: 0x0A) {
                        let lineData = buffer.subdata(in: buffer.startIndex..<newline)
                        buffer.removeSubrange(buffer.startIndex...newline)
                        if let line = String(data: lineData, encoding: .utf8),
                           !line.trimmingCharacters(in: .whitespaces).isEmpty {
                            continuation.yield(line)
                        }
                    }
                }
                if let tail = String(data: buffer, encoding: .utf8),
                   !tail.trimmingCharacters(in: .whitespaces).isEmpty {
                    continuation.yield(tail)
                }
                process.waitUntilExit()
                continuation.finish()
            }
        }
    }
}
#endif
