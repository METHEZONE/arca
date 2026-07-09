import AVFoundation
import Foundation

/// Sends a request body and returns (data, response).
///
/// URLSession deadlocks over HTTP/2 for large request bodies against some
/// servers (reproduced: the Anthropic API with an inline image never returns,
/// and even the request timeout doesn't fire — while the identical request over
/// HTTP/1.1 via curl completes in a few seconds). On macOS we therefore route
/// through curl, which is always present and negotiates a working transport.
/// Small bodies and other platforms use URLSession directly.
public func uploadBody(_ session: URLSession, for request: URLRequest, body: Data) async throws -> (Data, URLResponse) {
    #if os(macOS)
    if body.count > 32 * 1024 {
        return try await CurlTransport.send(request: request, body: body)
    }
    #endif
    return try await session.upload(for: request, from: body)
}

#if os(macOS)
/// Minimal curl-backed HTTP transport for large POST bodies. Non-sandboxed
/// macOS only. Streams the body from a temp file and parses status + body.
enum CurlTransport {
    static func send(request: URLRequest, body: Data) async throws -> (Data, URLResponse) {
        guard let url = request.url else { throw URLError(.badURL) }
        let bodyFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("arca-curl-\(UUID().uuidString).bin")
        try body.write(to: bodyFile)
        defer { try? FileManager.default.removeItem(at: bodyFile) }

        // Honor a caller-raised timeout (long transcription jobs); never go
        // below the old 120s floor.
        let maxTime = Int(max(120, request.timeoutInterval))
        var args = [
            "--silent", "--show-error", "--max-time", "\(maxTime)",
            "-X", request.httpMethod ?? "POST",
            "--data-binary", "@\(bodyFile.path)",
            "-w", "\n%{http_code}",
        ]
        for (key, value) in request.allHTTPHeaderFields ?? [:] {
            args.append(contentsOf: ["-H", "\(key): \(value)"])
        }
        args.append(url.absoluteString)

        let (out, status) = try await runProcess("/usr/bin/curl", args)
        guard status == 0 else {
            let code: URLError.Code = status == 28 ? .timedOut : .cannotConnectToHost
            throw URLError(code, userInfo: [NSLocalizedDescriptionKey: "curl exit \(status)"])
        }
        // Last line is the HTTP status code (from -w); everything before is the body.
        guard let newline = out.lastIndex(of: 0x0A) else {
            throw URLError(.badServerResponse)
        }
        let bodyData = out.subdata(in: out.startIndex..<newline)
        let codeString = String(decoding: out.subdata(in: out.index(after: newline)..<out.endIndex), as: UTF8.self)
        let code = Int(codeString.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        let response = HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: nil)!
        return (bodyData, response)
    }

    private static func runProcess(_ launchPath: String, _ arguments: [String]) async throws -> (Data, Int32) {
        // Run entirely on a detached thread: read the pipe to EOF (blocks until
        // the child closes it) then wait for exit. Avoids terminationHandler /
        // run-loop delivery issues when called from a GUI app's async context.
        try await withCheckedThrowingContinuation { continuation in
            Thread.detachNewThread {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: launchPath)
                process.arguments = arguments
                let outPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                    let data = outPipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    continuation.resume(returning: (data, process.terminationStatus))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
#endif

/// A live audio buffer flowing from capture to the streaming transcriber.
/// The buffer is handed off exactly once and must not be mutated after yield —
/// that hand-off discipline is what makes the @unchecked Sendable sound.
public struct CapturedBuffer: @unchecked Sendable {
    public let channel: CaptureChannel
    public let buffer: AVAudioPCMBuffer
    /// Seconds since the start of the capture session (frame-counter derived).
    public let elapsed: TimeInterval

    public init(channel: CaptureChannel, buffer: AVAudioPCMBuffer, elapsed: TimeInterval) {
        self.channel = channel
        self.buffer = buffer
        self.elapsed = elapsed
    }
}

/// AVAudioConverter wrapper for format conversion between capture, file, and
/// analyzer formats. Not thread-safe; confine to one processing chain.
public final class BufferConverter {
    private var converter: AVAudioConverter?

    public init() {}

    public enum ConversionError: Error {
        case converterCreationFailed
        case bufferAllocationFailed
        case conversionFailed(String)
    }

    public func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        if buffer.format == format { return buffer }

        if converter == nil || converter?.inputFormat != buffer.format || converter?.outputFormat != format {
            converter = AVAudioConverter(from: buffer.format, to: format)
            converter?.primeMethod = .none
        }
        guard let converter else { throw ConversionError.converterCreationFailed }

        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw ConversionError.bufferAllocationFailed
        }

        // The AVAudioConverter input block runs synchronously within convert();
        // the unsafe markers silence Sendable diagnostics for that sync use.
        nonisolated(unsafe) var consumed = false
        nonisolated(unsafe) let source = buffer
        var conversionError: NSError?
        converter.convert(to: output, error: &conversionError) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return source
        }
        if let conversionError {
            throw ConversionError.conversionFailed(conversionError.localizedDescription)
        }
        return output
    }
}
