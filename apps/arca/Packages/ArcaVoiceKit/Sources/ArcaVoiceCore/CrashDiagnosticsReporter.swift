import Foundation
#if canImport(MetricKit)
import MetricKit
#endif

/// Reports crashes and hangs back to ARCA Cloud, using Apple's own MetricKit
/// instead of a third-party crash SDK.
///
/// The app ships with no Firebase or Sentry, and adding one for a beta among a
/// handful of devices would cost more than it returns: MetricKit is in the OS,
/// needs no account, no symbol upload, and no extra bytes in the bundle.
///
/// The price is latency. iOS does NOT deliver a diagnostic at the moment of the
/// crash — it collects the payload and hands it over on a later launch, usually
/// the next one, sometimes up to about a day afterwards. Nothing arriving right
/// after you force a crash is expected behaviour, not a broken pipe. In
/// exchange the payload contains the real thing: symbolicated call-stack trees,
/// the exception/signal, and the OS's own termination reason.
///
/// Delivery is best-effort and silent. A diagnostics reporter that surfaces its
/// own network errors to a user who just lost their app would be worse than
/// useless.
#if canImport(MetricKit) && (os(iOS) || os(macOS))
public final class CrashDiagnosticsReporter: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    public static let shared = CrashDiagnosticsReporter()

    /// Guard against a pathological call-stack tree filling the request.
    private static let maxReportBytes = 1_500_000

    private override init() { super.init() }

    /// Subscribes to MetricKit. Call once, at launch: payloads pending from a
    /// previous run are delivered shortly after subscribing, which is exactly
    /// how a crash from the last session gets reported.
    @MainActor
    public static func start() {
        MXMetricManager.shared.add(shared)
    }

    // MARK: - MXMetricManagerSubscriber

    /// Required by the protocol. Performance metrics are not what this is for.
    public func didReceive(_ payloads: [MXMetricPayload]) {}

    public func didReceive(_ payloads: [MXDiagnosticPayload]) {
        var reports: [[String: Any]] = []
        for payload in payloads {
            for crash in payload.crashDiagnostics ?? [] {
                reports.append(summary(of: crash))
            }
            for hang in payload.hangDiagnostics ?? [] {
                reports.append(summary(of: hang))
            }
        }
        guard !reports.isEmpty else { return }
        send(reports)
    }

    // MARK: - Summaries

    private func summary(of crash: MXCrashDiagnostic) -> [String: Any] {
        var report = base(kind: "crash", metaData: crash.metaData,
                          appVersion: crash.applicationVersion,
                          callStackTree: crash.callStackTree)
        if let type = crash.exceptionType { report["exceptionType"] = type.intValue }
        if let code = crash.exceptionCode { report["exceptionCode"] = code.intValue }
        if let signal = crash.signal { report["signal"] = signal.intValue }
        if let reason = crash.terminationReason { report["terminationReason"] = reason }
        if let region = crash.virtualMemoryRegionInfo { report["virtualMemoryRegionInfo"] = region }
        return report
    }

    private func summary(of hang: MXHangDiagnostic) -> [String: Any] {
        var report = base(kind: "hang", metaData: hang.metaData,
                          appVersion: hang.applicationVersion,
                          callStackTree: hang.callStackTree)
        report["hangSeconds"] = hang.hangDuration.converted(to: .seconds).value
        return report
    }

    private func base(kind: String, metaData: MXMetaData, appVersion: String,
                      callStackTree: MXCallStackTree) -> [String: Any] {
        var report: [String: Any] = [
            "kind": kind,
            "installId": ArcaConfig.installId,
            "receivedAt": ISO8601DateFormatter().string(from: Date()),
            "appVersion": appVersion,
            "buildVersion": metaData.applicationBuildVersion,
            "osVersion": metaData.osVersion,
            "deviceModel": metaData.deviceType,
            "platformArchitecture": metaData.platformArchitecture,
            "platform": platformName,
        ]
        // The call-stack tree is the whole point — it is what says *where* the
        // crash was. Embedded as parsed JSON so the backend can read it without
        // a second decode.
        if let tree = try? JSONSerialization.jsonObject(with: callStackTree.jsonRepresentation()) {
            report["callStackTree"] = tree
        }
        return report
    }

    private var platformName: String {
        #if os(iOS)
        return "iOS"
        #else
        return "macOS"
        #endif
    }

    // MARK: - Delivery

    private func send(_ reports: [[String: Any]]) {
        let payload: [String: Any] = ["installId": ArcaConfig.installId, "reports": reports]
        guard var body = try? JSONSerialization.data(withJSONObject: payload) else { return }
        if body.count > Self.maxReportBytes {
            // Too big to be worth posting whole: drop the stacks, keep the fact
            // that it happened and what killed it.
            let trimmed = reports.map { report -> [String: Any] in
                var copy = report
                copy["callStackTree"] = nil
                copy["callStackTreeOmitted"] = true
                return copy
            }
            guard let smaller = try? JSONSerialization.data(
                withJSONObject: ["installId": ArcaConfig.installId, "reports": trimmed]) else { return }
            body = smaller
        }

        var request = URLRequest(url: ArcaConfig.cloudEndpoint("api/arca/crash"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        let session = URLSession.shared
        Task.detached {
            _ = try? await session.upload(for: request, from: body)
        }
    }
}
#endif
