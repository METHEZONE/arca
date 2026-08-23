#if os(iOS)
import Foundation

/// Uploads a request whose body is already a file, through a background
/// `URLSession`.
///
/// The transcription pass is a multi-minute upload. It used to run on
/// `URLSession.shared` under a `beginBackgroundTask` assertion, which iOS grants
/// for roughly 30 seconds — nowhere near one chunk's 600-second request timeout,
/// let alone several of them. The moment the phone went into a pocket the upload
/// was killed and the session was left stranded.
///
/// A background session is performed out of process by `nsurlsessiond`: the
/// transfer continues while the app is suspended, and with
/// `sessionSendsLaunchEvents` iOS relaunches the app to hand back the result via
/// `application(_:handleEventsForBackgroundURLSession:completionHandler:)`.
///
/// Scope, stated honestly: this survives *suspension*, which is the failure the
/// users hit. It does not resume a single in-flight upload across a full
/// *termination* — the awaiting continuation dies with the process, and
/// reattributing an orphaned response to its chunk would need a persistent
/// upload ledger plus chunk files in durable storage (they are exported into the
/// purgeable temporary directory today). That case is covered instead by the
/// session row staying in `.processing`, which `SessionRecovery.needsFinalPass`
/// picks up on the next launch — including a background launch — and redoes from
/// the intact audio.
public final class BackgroundUploader: NSObject, @unchecked Sendable {
    public static let shared = BackgroundUploader()

    /// One identifier per process. Recreating the session with the same
    /// identifier at launch is what lets iOS deliver work finished while the app
    /// was away, so this must stay stable across releases.
    public static let sessionIdentifier = "com.thezone.arca.voice.transcribe-upload"

    /// Bounded so a wedged transfer eventually fails instead of hanging for the
    /// 7-day default.
    private static let resourceTimeout: TimeInterval = 3600

    private final class Waiter {
        var body = Data()
        var continuation: CheckedContinuation<(Data, URLResponse), Error>?
    }

    private let lock = NSLock()
    private var waiters: [Int: Waiter] = [:]
    private var launchCompletion: (@Sendable () -> Void)?
    private var session: URLSession!

    private override init() {
        super.init()
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        config.sessionSendsLaunchEvents = true
        // Discretionary transfers get deferred to "a convenient time", which for
        // a meeting the user just finished is the wrong trade.
        config.isDiscretionary = false
        config.allowsCellularAccess = true
        config.timeoutIntervalForResource = Self.resourceTimeout
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    /// Recreates the shared session if it was torn down, so a background launch
    /// has somewhere to deliver its events. Cheap and idempotent.
    public static func prepareForBackgroundLaunch() {
        _ = shared
    }

    public func upload(_ request: URLRequest, bodyFile: URL) async throws -> (Data, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            let task = session.uploadTask(with: request, fromFile: bodyFile)
            let waiter = Waiter()
            waiter.continuation = continuation
            lock.lock()
            waiters[task.taskIdentifier] = waiter
            lock.unlock()
            task.resume()
        }
    }

    /// Stored by the app delegate; called once the session says it has delivered
    /// everything it finished while the app was suspended or terminated.
    public func setLaunchCompletionHandler(_ handler: @escaping @Sendable () -> Void) {
        lock.lock()
        launchCompletion = handler
        lock.unlock()
    }

    private func take(_ identifier: Int) -> Waiter? {
        lock.lock()
        defer { lock.unlock() }
        return waiters.removeValue(forKey: identifier)
    }
}

extension BackgroundUploader: URLSessionDataDelegate {
    /// Upload tasks are data tasks: a background session hands the response body
    /// back here rather than through a completion handler.
    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        waiters[dataTask.taskIdentifier]?.body.append(data)
        lock.unlock()
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let waiter = take(task.taskIdentifier),
              let continuation = waiter.continuation else {
            // No waiter: this task finished while the app was not running, so
            // whoever asked for it is long gone. The stranded-session scan
            // redoes the pass instead.
            return
        }
        waiter.continuation = nil
        if let error {
            continuation.resume(throwing: error)
        } else if let response = task.response {
            continuation.resume(returning: (waiter.body, response))
        } else {
            continuation.resume(throwing: URLError(.badServerResponse))
        }
    }

    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        lock.lock()
        let handler = launchCompletion
        launchCompletion = nil
        lock.unlock()
        guard let handler else { return }
        DispatchQueue.main.async { handler() }
    }
}
#endif
