import Foundation

/// Appends timestamped markers to a file in the app container. NSLog does not
/// reliably surface to the unified log for sandboxed apps launched via `open`,
/// so this is the trace of record during bring-up.
import ArcaVoiceKit

enum DebugTrace {
    /// Routes the vision planner's internal trace into this file too.
    static func install() {
        ClaudeVisionPlanner.trace = { message in DebugTrace.log("vision: \(message)") }
    }

    private static let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("ArcaVoice/trace.log")
    }()

    static func log(_ message: String) {
        let line = "\(Date().timeIntervalSince1970) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }
}
