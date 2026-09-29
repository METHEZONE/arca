import Foundation

/// An error that may go away on its own — a dropped connection, a rate limit,
/// an overloaded provider — as opposed to one that will fail the same way
/// every time (a bad key, a malformed request).
public protocol TransientError: Error {
    var isTransient: Bool { get }
}

/// HTTP statuses worth asking again for. 529 is Anthropic's "overloaded".
public func isTransientHTTPStatus(_ status: Int) -> Bool {
    [408, 425, 429, 500, 502, 503, 504, 529].contains(status)
}

/// Whether a transport-level failure is the network's fault. A cancellation is
/// deliberate and must not be retried.
public func isTransientTransportError(_ error: Error) -> Bool {
    if error is CancellationError { return false }
    if let urlError = error as? URLError { return urlError.code != .cancelled }
    return true
}

/// Runs `operation`, retrying it after each delay while it throws a transient
/// error. One flaky moment on the subway used to cost a meeting its transcript
/// or its summary until the next launch; now it costs a few seconds.
public func withTransientRetry<T: Sendable>(
    delays: [Duration] = [.seconds(2), .seconds(6), .seconds(15)],
    _ operation: () async throws -> T
) async throws -> T {
    var attempt = 0
    while true {
        do {
            return try await operation()
        } catch let error as TransientError where error.isTransient && attempt < delays.count {
            try await Task.sleep(for: delays[attempt])
            attempt += 1
        }
    }
}
