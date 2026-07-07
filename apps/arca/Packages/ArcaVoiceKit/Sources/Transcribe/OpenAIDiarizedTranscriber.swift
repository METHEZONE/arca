import AVFoundation
import Foundation
import ArcaVoiceCore

/// Final-pass transcriber backed by OpenAI's diarizing speech-to-text model.
///
/// Uploads one channel's audio file to `POST /v1/audio/transcriptions` with
/// `model=gpt-4o-transcribe-diarize` and `response_format=diarized_json`, then
/// maps the returned speaker-labeled segments into a `Transcript`. The API's
/// per-segment `speaker` label becomes `Segment.speakerLabel`.
///
/// Recordings longer than the model's duration cap (1400s) or bigger than the
/// upload cap (25MB) are split into equal chunks, transcribed concurrently,
/// and stitched back together with chunk-offset timestamps.
///
/// BYOK: the key is passed at init (read from the Keychain by the caller).
public struct OpenAIDiarizedTranscriber: FinalTranscriber {
    /// OpenAI's hard cap on a single upload.
    public static let maxUploadBytes = 25 * 1024 * 1024
    /// The model rejects audio over 1400s; chunk below that with headroom.
    public static let maxChunkSeconds: Double = 1320

    private let apiKey: String
    private let model: String
    private let endpoint: URL
    private let urlSession: URLSession

    public init(
        apiKey: String,
        model: String = "gpt-4o-transcribe-diarize",
        endpoint: URL = URL(string: "https://api.openai.com/v1/audio/transcriptions")!,
        urlSession: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.model = model
        self.endpoint = endpoint
        self.urlSession = urlSession
    }

    public func transcribe(fileURL: URL, channel: CaptureChannel, hints: TranscriptHints) async throws -> Transcript {
        let fileSize = try Self.fileSize(of: fileURL)
        let duration = (try? await AVURLAsset(url: fileURL).load(.duration).seconds) ?? 0

        if duration > Self.maxChunkSeconds || fileSize > Self.maxUploadBytes {
            return try await transcribeChunked(
                fileURL: fileURL, channel: channel, hints: hints,
                duration: duration, fileSize: fileSize)
        }
        return try await transcribeSingle(fileURL: fileURL, channel: channel, hints: hints)
    }

    private func transcribeSingle(fileURL: URL, channel: CaptureChannel, hints: TranscriptHints) async throws -> Transcript {
        let fileSize = try Self.fileSize(of: fileURL)
        guard fileSize <= Self.maxUploadBytes else {
            throw OpenAITranscriptionError.fileTooLarge(bytes: fileSize, limit: Self.maxUploadBytes)
        }

        let audioData = try Data(contentsOf: fileURL)
        let boundary = "arca-\(UUID().uuidString)"

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        // Server-side transcription of a ~20-minute chunk can take several
        // minutes — the default 60s (and curl's old 120s cap) cut it off.
        request.timeoutInterval = 600
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let multipart = Self.multipartBody(
            boundary: boundary,
            fileName: fileURL.lastPathComponent,
            audioData: audioData,
            model: model,
            languageHint: hints.languageCodes.first
        )

        // upload(from:) rather than a large httpBody + data(for:), which can
        // hang over HTTP/2 for multi-MB audio uploads.
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await uploadBody(urlSession, for: request, body: multipart)
        } catch {
            throw OpenAITranscriptionError.transport(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw OpenAITranscriptionError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw OpenAITranscriptionError.api(status: http.statusCode, message: Self.apiErrorMessage(from: data))
        }

        return try Self.decodeTranscript(from: data, channel: channel)
    }

    // MARK: - Chunking (long/large recordings)

    /// Splits the recording into equal chunks that satisfy both the duration
    /// and the upload-size caps, transcribes them concurrently, and stitches
    /// the segments back together with each chunk's start-time offset.
    /// Speaker labels are per-request (A/B/…), so the same label across chunks
    /// merges into one speaker — right for "the most talkative other side",
    /// which is what our mic/system channel split needs.
    private func transcribeChunked(
        fileURL: URL, channel: CaptureChannel, hints: TranscriptHints,
        duration: Double, fileSize: Int
    ) async throws -> Transcript {
        guard duration > 1 else {
            // No readable duration — nothing to slice on. One honest attempt.
            return try await transcribeSingle(fileURL: fileURL, channel: channel, hints: hints)
        }
        let byDuration = Int((duration / Self.maxChunkSeconds).rounded(.up))
        // Export re-encodes to AAC, but keep a size-derived floor anyway.
        let sizeBudget = Self.maxUploadBytes * 4 / 5
        let bySize = Int((Double(fileSize) / Double(sizeBudget)).rounded(.up))
        let count = max(byDuration, bySize, 1)
        let chunkLength = duration / Double(count)

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("arca-chunks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        var chunks: [(index: Int, start: Double, url: URL)] = []
        for index in 0..<count {
            let start = Double(index) * chunkLength
            let length = min(chunkLength, duration - start)
            let chunkURL = tempDir.appendingPathComponent("chunk-\(index).m4a")
            try await Self.exportChunk(of: fileURL, to: chunkURL, start: start, length: length)
            chunks.append((index, start, chunkURL))
        }

        let pieces = try await withThrowingTaskGroup(
            of: (Int, Double, Transcript).self
        ) { group in
            for chunk in chunks {
                group.addTask {
                    let transcript = try await transcribeSingle(
                        fileURL: chunk.url, channel: channel, hints: hints)
                    return (chunk.index, chunk.start, transcript)
                }
            }
            var collected: [(Int, Double, Transcript)] = []
            for try await piece in group { collected.append(piece) }
            return collected.sorted { $0.0 < $1.0 }
        }

        var segments: [Transcript.Segment] = []
        for (_, offset, transcript) in pieces {
            for segment in transcript.segments {
                segments.append(Transcript.Segment(
                    text: segment.text,
                    start: segment.start + offset,
                    end: segment.end + offset,
                    confidence: segment.confidence,
                    speakerLabel: segment.speakerLabel))
            }
        }
        let language = pieces.first { !($0.2.languageCode ?? "").isEmpty }?.2.languageCode
        return Transcript(channel: channel, segments: segments, languageCode: language)
    }

    /// Cuts `[start, start+length)` out of the source audio as an AAC m4a.
    private static func exportChunk(of source: URL, to destination: URL,
                                    start: Double, length: Double) async throws {
        let asset = AVURLAsset(url: source)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw OpenAITranscriptionError.chunking("Could not create an audio export session.")
        }
        export.timeRange = CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 600),
            duration: CMTime(seconds: length, preferredTimescale: 600))
        do {
            try await export.export(to: destination, as: .m4a)
        } catch {
            throw OpenAITranscriptionError.chunking(
                "Exporting the \(Int(start))s–\(Int(start + length))s slice failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Request building

    /// The diarize model chunks internally (`chunking_strategy=auto`, required for
    /// audio over 30s). We ask for `diarized_json` to get per-speaker segments and
    /// pass a single `language` hint when available.
    public static func multipartBody(
        boundary: String,
        fileName: String,
        audioData: Data,
        model: String,
        languageHint: String?
    ) -> Data {
        var body = Data()

        func appendField(_ name: String, _ value: String) {
            body.appendString("--\(boundary)\r\n")
            body.appendString("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            body.appendString("\(value)\r\n")
        }

        appendField("model", model)
        appendField("response_format", "diarized_json")
        appendField("chunking_strategy", "auto")
        if let languageHint, !languageHint.isEmpty {
            appendField("language", languageHint)
        }

        body.appendString("--\(boundary)\r\n")
        body.appendString("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n")
        body.appendString("Content-Type: \(mimeType(for: fileName))\r\n\r\n")
        body.append(audioData)
        body.appendString("\r\n")

        body.appendString("--\(boundary)--\r\n")
        return body
    }

    private static func mimeType(for fileName: String) -> String {
        switch (fileName as NSString).pathExtension.lowercased() {
        case "wav": return "audio/wav"
        case "mp3": return "audio/mpeg"
        case "m4a": return "audio/mp4"
        case "mp4": return "audio/mp4"
        case "webm": return "audio/webm"
        case "flac": return "audio/flac"
        case "ogg": return "audio/ogg"
        default: return "application/octet-stream"
        }
    }

    // MARK: - Response decoding

    /// Diarized response shape: a top-level object with a `segments` array; each
    /// segment carries `speaker`, `start`, `end`, and `text`.
    struct DiarizedResponse: Decodable {
        struct Segment: Decodable {
            var text: String
            var start: Double?
            var end: Double?
            var speaker: String?
        }
        var task: String?
        var language: String?
        var text: String?
        var segments: [Segment]?
    }

    public static func decodeTranscript(from data: Data, channel: CaptureChannel) throws -> Transcript {
        let decoded: DiarizedResponse
        do {
            decoded = try JSONDecoder().decode(DiarizedResponse.self, from: data)
        } catch {
            throw OpenAITranscriptionError.decoding(error)
        }

        let segments: [Transcript.Segment] = (decoded.segments ?? []).map { seg in
            Transcript.Segment(
                text: seg.text,
                start: seg.start ?? 0,
                end: seg.end ?? seg.start ?? 0,
                confidence: nil,
                speakerLabel: seg.speaker
            )
        }
        return Transcript(channel: channel, segments: segments, languageCode: decoded.language)
    }

    // MARK: - Errors

    /// OpenAI error bodies are `{"error": {"message": "...", ...}}`. Fall back to
    /// the raw body if that shape is absent.
    public static func apiErrorMessage(from data: Data) -> String {
        struct ErrorEnvelope: Decodable {
            struct APIError: Decodable { var message: String? }
            var error: APIError?
        }
        if let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: data),
           let message = envelope.error?.message, !message.isEmpty {
            return message
        }
        if let raw = String(data: data, encoding: .utf8), !raw.isEmpty {
            return raw
        }
        return "Unknown error."
    }

    private static func fileSize(of url: URL) throws -> Int {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        return values.fileSize ?? 0
    }
}

/// LocalizedError conformance matters: FinalPassRunner stores
/// `error.localizedDescription`, which without it collapses to the useless
/// "(Transcribe.OpenAITranscriptionError error 2.)".
public enum OpenAITranscriptionError: Error, CustomStringConvertible, LocalizedError {
    case fileTooLarge(bytes: Int, limit: Int)
    case transport(Error)
    case invalidResponse
    case api(status: Int, message: String)
    case decoding(Error)
    case chunking(String)

    public var description: String {
        switch self {
        case .fileTooLarge(let bytes, let limit):
            let mb = Double(bytes) / (1024 * 1024)
            let limitMB = limit / (1024 * 1024)
            return String(format: "An audio chunk is %.1f MB, over the %d MB OpenAI upload limit.", mb, limitMB)
        case .transport(let error):
            return "Network error contacting OpenAI: \(error.localizedDescription)"
        case .invalidResponse:
            return "OpenAI returned a response that was not HTTP."
        case .api(let status, let message):
            return "OpenAI transcription failed (HTTP \(status)): \(message)"
        case .decoding(let error):
            return "Could not parse the OpenAI transcription response: \(error.localizedDescription)"
        case .chunking(let message):
            return "Could not split the recording for transcription: \(message)"
        }
    }

    public var errorDescription: String? { description }
}

private extension Data {
    mutating func appendString(_ string: String) {
        if let data = string.data(using: .utf8) {
            append(data)
        }
    }
}
