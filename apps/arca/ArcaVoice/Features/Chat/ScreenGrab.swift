#if os(macOS)
import AppKit

/// Captures the screen and returns a bounded JPEG for a vision chat turn.
/// Shells to `screencapture` (needs Screen Recording permission, prompted once).
enum ScreenGrab {
    static func fullScreenJPEG(maxDimension: CGFloat = 1600) async -> (Data, String)? {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("arca-screen-\(UUID().uuidString).png")
        let ok = await run("/usr/sbin/screencapture", ["-x", tmp.path])
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard ok, FileManager.default.fileExists(atPath: tmp.path) else { return nil }
        return ImageDownscaler.jpeg(from: tmp, maxDimension: maxDimension)
    }

    private static func run(_ path: String, _ args: [String]) async -> Bool {
        await withCheckedContinuation { continuation in
            Thread.detachNewThread {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = args
                do {
                    try process.run()
                    process.waitUntilExit()
                    continuation.resume(returning: process.terminationStatus == 0)
                } catch {
                    continuation.resume(returning: false)
                }
            }
        }
    }
}
#endif
