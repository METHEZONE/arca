#if os(macOS)
import AppKit

/// Captures the screen and returns a bounded JPEG for a vision chat turn.
/// Shells to `screencapture` (needs Screen Recording permission, prompted once).
enum ScreenGrab {
    static func fullScreenJPEG(maxDimension: CGFloat = 1600) async -> (Data, String)? {
        guard await MainActor.run(body: { ScreenCapturePermission.requestOnce() }) else { return nil }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("arca-screen-\(UUID().uuidString).png")
        let ok = await run("/usr/sbin/screencapture", ["-x", tmp.path])
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard ok, FileManager.default.fileExists(atPath: tmp.path) else { return nil }
        return ImageDownscaler.jpeg(from: tmp, maxDimension: maxDimension)
    }

    /// Captures the video-call window when one is on screen (matched by window
    /// title), the full screen otherwise. Used by the meeting roster watcher.
    static func meetingWindowJPEG(maxDimension: CGFloat = 1600) async -> (Data, String)? {
        guard await MainActor.run(body: { ScreenCapturePermission.granted }) else { return nil }
        if let windowID = meetingWindowID() {
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("arca-meet-\(UUID().uuidString).png")
            let ok = await run("/usr/sbin/screencapture", ["-x", "-o", "-l", String(windowID), tmp.path])
            defer { try? FileManager.default.removeItem(at: tmp) }
            if ok, FileManager.default.fileExists(atPath: tmp.path),
               let jpeg = ImageDownscaler.jpeg(from: tmp, maxDimension: maxDimension) {
                return jpeg
            }
        }
        return await fullScreenJPEG(maxDimension: maxDimension)
    }

    /// The on-screen window that looks like a live call. Window titles need
    /// Screen Recording permission — already granted for meeting capture.
    private static func meetingWindowID() -> CGWindowID? {
        guard let info = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return nil }
        let needles = ["meet", "zoom", "webex", "huddle", "화상"]
        for entry in info {
            guard let layer = entry[kCGWindowLayer as String] as? Int, layer == 0,
                  let title = entry[kCGWindowName as String] as? String, !title.isEmpty,
                  let number = entry[kCGWindowNumber as String] as? Int,
                  let bounds = entry[kCGWindowBounds as String] as? [String: CGFloat],
                  (bounds["Width"] ?? 0) > 500, (bounds["Height"] ?? 0) > 350 else { continue }
            let lower = title.lowercased()
            if needles.contains(where: { lower.contains($0) }) {
                return CGWindowID(number)
            }
        }
        return nil
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
