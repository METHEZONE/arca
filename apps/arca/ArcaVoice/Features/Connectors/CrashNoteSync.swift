#if os(macOS)
import Foundation
import ArcaVoiceKit

/// macOS only — turns crashes that happened on the *iPhone* into ARCA dev notes
/// in the Obsidian vault.
///
/// The two hops are not an accident. `CrashDiagnosticsReporter` runs wherever the
/// crash happened (usually the phone) and can only POST somewhere; the vault is a
/// folder on this Mac's disk, which a serverless function cannot write to. So the
/// cloud endpoint is used as an inbox and the Mac — the side that actually has
/// the vault, and is the side sitting on the desk — drains it.
///
/// Silent by design when unconfigured: no cloud base URL, no vault path, or an
/// unreachable host all end as a no-op, because a diagnostics pipeline that
/// nags is worse than one that waits. Only an actual delivered report speaks up.
@MainActor
enum CrashNoteSync {
    /// Crash diagnostics are already a day late by the time MetricKit hands them
    /// over, so polling faster buys nothing.
    private static let pollEvery: TimeInterval = 30 * 60
    /// First poll ever: bound the backfill instead of importing the whole inbox.
    private static let firstRunLookback: TimeInterval = 7 * 86_400
    /// A crash whose stack fills a screen is triageable; one that fills a file is not.
    private static let maxStackLines = 200

    private static let lastPollKey = "crashNoteLastPollAt"
    private static let cursorKey = "crashNoteLastSeenAt"

    static func runIfDue(now: Date = .now) async {
        let defaults = UserDefaults.standard
        let last = defaults.double(forKey: lastPollKey)
        guard now.timeIntervalSince1970 - last > pollEvery else { return }
        defaults.set(now.timeIntervalSince1970, forKey: lastPollKey)

        guard let vault = vaultURL() else { return }

        let since = defaults.string(forKey: cursorKey)
            ?? isoString(from: now.addingTimeInterval(-firstRunLookback))
        guard let reports = await fetchReports(since: since), !reports.isEmpty else { return }

        var newestSeen = since
        var written = 0
        for report in reports {
            let at = report["at"] as? String
            do {
                let url = try ObsidianExporter.writeNote(
                    fileName: fileName(for: report, at: at),
                    markdown: markdown(for: report, at: at),
                    to: vault)
                written += 1
                DebugTrace.log("crash note written: \(url.lastPathComponent)")
            } catch {
                DebugTrace.log("crash note write failed: \(error)")
                continue
            }
            // The server's `at` is always the same ISO-8601 UTC shape, so string
            // order is chronological order — no parsing needed for the cursor.
            if let at, at > newestSeen { newestSeen = at }
        }

        defaults.set(newestSeen, forKey: cursorKey)
        if written > 0 {
            AppServices.shared.notch.showNotice(
                "크래시 리포트 \(written)개를 옵시디언 ARCA 폴더에 적어뒀어요", seconds: 7)
        }
    }

    // MARK: - Inbox

    /// The vault this app is pointed at, or nil. Same setting the meeting export
    /// and the memory import use — there is only one vault.
    private static func vaultURL() -> URL? {
        let path = AccountDefaults.string("obsidianVaultPath")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
    }

    private static func fetchReports(since: String) async -> [[String: Any]]? {
        var components = URLComponents(
            url: ArcaConfig.cloudEndpoint("api/arca/crash"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "since", value: since)]
        guard let url = components?.url else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                DebugTrace.log("crash note poll: unexpected response")
                return nil
            }
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            return object?["reports"] as? [[String: Any]]
        } catch {
            // Wrong host, offline, deploy asleep — all the same non-event.
            DebugTrace.log("crash note poll failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Note

    private static func fileName(for report: [String: Any], at: String?) -> String {
        let date = parseISO(at) ?? .now
        let device = slugify(report["deviceModel"] as? String ?? "unknown")
        return "\(dayString(from: date)) \(compactTimeString(from: date)) ARCA 크래시 \(device).md"
    }

    private static func markdown(for report: [String: Any], at: String?) -> String {
        let date = parseISO(at) ?? .now
        let device = report["deviceModel"] as? String ?? "알 수 없는 기기"
        let isHang = (report["kind"] as? String) == "hang"

        var lines: [String] = [
            "---",
            "date: \(isoString(from: date))",
            "source: arca",
            "type: crash",
            "---",
            "",
            "# ARCA 크래시 리포트 - \(dayString(from: date)) \(device)",
            "",
            "- 종류: \(isHang ? "행(응답 없음)" : "크래시")",
        ]

        if isHang, let seconds = report["hangSeconds"] as? Double {
            lines.append("- 멈춘 시간: \(String(format: "%.1f", seconds))초")
        }
        for (label, key) in [("예외 타입", "exceptionType"), ("예외 코드", "exceptionCode"),
                             ("시그널", "signal")] {
            if let value = report[key] as? Int { lines.append("- \(label): \(value)") }
        }
        if let reason = report["terminationReason"] as? String, !reason.isEmpty {
            lines.append("- 종료 사유: \(reason)")
        }
        lines.append("- 앱: \(report["appVersion"] as? String ?? "?") (\(report["buildVersion"] as? String ?? "?"))")
        lines.append("- OS: \(report["platform"] as? String ?? "?") \(report["osVersion"] as? String ?? "?")")
        lines.append("- 기기: \(device) \(report["platformArchitecture"] as? String ?? "")"
            .trimmingCharacters(in: .whitespaces))
        if let installId = report["installId"] as? String, !installId.isEmpty {
            lines.append("- 인스톨: \(installId)")
        }
        if let receivedAt = report["receivedAt"] as? String, !receivedAt.isEmpty {
            lines.append("- 기기에서 수집한 시각: \(receivedAt)")
        }
        if let region = report["virtualMemoryRegionInfo"] as? String, !region.isEmpty {
            lines.append("- 메모리 영역: \(region)")
        }
        lines.append("")

        lines.append("## 콜스택")
        lines.append("```text")
        if report["callStackTreeOmitted"] as? Bool == true {
            lines.append("(너무 커서 전송 단계에서 생략됨)")
        } else {
            let stack = stackLines(from: report["callStackTree"])
            lines.append(contentsOf: stack.isEmpty ? ["(콜스택 없음)"] : stack)
        }
        lines.append("```")
        lines.append("")
        return lines.joined(separator: "\n")
    }

    /// Flattens MetricKit's `callStackTree` JSON into an indented frame list.
    /// The tree's own shape (`callStacks` → `callStackRootFrames` → `subFrames`)
    /// is a sampling tree, so the indentation is the call depth.
    private static func stackLines(from tree: Any?) -> [String] {
        guard let tree = tree as? [String: Any],
              let stacks = tree["callStacks"] as? [[String: Any]] else { return [] }
        var lines: [String] = []

        func append(frame: [String: Any], depth: Int) {
            guard lines.count < maxStackLines else { return }
            let name = frame["binaryName"] as? String ?? "?"
            let offset = frame["offsetIntoBinaryTextSegment"] as? Int
            let indent = String(repeating: "  ", count: depth)
            lines.append("\(indent)\(name)\(offset.map { " +\($0)" } ?? "")")
            for sub in frame["subFrames"] as? [[String: Any]] ?? [] {
                append(frame: sub, depth: depth + 1)
            }
        }

        for (index, stack) in stacks.enumerated() {
            guard lines.count < maxStackLines else { break }
            let attributed = stack["threadAttributed"] as? Bool == true
            lines.append("Thread \(index)\(attributed ? " (crashed)" : "")")
            for frame in stack["callStackRootFrames"] as? [[String: Any]] ?? [] {
                append(frame: frame, depth: 1)
            }
        }
        if lines.count >= maxStackLines {
            lines.append("… (\(maxStackLines)줄에서 잘림)")
        }
        return lines
    }

    // MARK: - Dates

    private static func parseISO(_ string: String?) -> Date? {
        guard let string else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFraction.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }

    private static func isoString(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func dayString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func compactTimeString(from date: Date) -> String {
        let formatter = DateFormatter()
        // Seconds included so a crash loop on one device writes one note per
        // crash instead of overwriting itself.
        formatter.dateFormat = "HHmmss"
        return formatter.string(from: date)
    }

    private static func slugify(_ value: String) -> String {
        let cleaned = value
            .replacingOccurrences(of: #"[^A-Za-z0-9]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return cleaned.isEmpty ? "unknown" : cleaned
    }
}
#endif
