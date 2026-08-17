import AVFoundation
import Foundation
import ArcaVoiceCore

/// Final-pass transcriber backed by OpenAI speech-to-text.
///
/// Uploads one channel's audio file to `POST /v1/audio/transcriptions` and maps
/// the returned segments into a `Transcript`.
///
/// The model is `whisper-1`, not `gpt-4o-transcribe-diarize`, despite the type
/// name (kept for source compatibility). On far-field Korean room audio the
/// diarizing model measured 9% Hangul and looped on hallucinated English, while
/// `whisper-1` with an explicit `language` hint measured 95–99% on the same
/// recordings — the same finding that made the web backend
/// (`app/api/arca/transcribe/route.ts`) pick whisper. Diarization is not worth
/// losing the transcript, so segments come back without a `speaker` label and
/// each channel collapses to one speaker (`ProcessingPipeline` falls back to
/// "S1"). Mic-vs-system channel separation, not the model, is what still
/// distinguishes you from everyone else in the room.
///
/// Recordings longer than `maxChunkSeconds` or bigger than the upload cap
/// (25MB) are split into equal chunks, transcribed a few at a time, and
/// stitched back together with chunk-offset timestamps.
///
/// BYOK: the key is passed at init (read from the Keychain by the caller).
public struct OpenAIDiarizedTranscriber: FinalTranscriber {
    /// OpenAI's hard cap on a single upload.
    public static let maxUploadBytes = 25 * 1024 * 1024
    /// Chunk length for long recordings. Whisper has no duration cap of its
    /// own, but shorter requests fail smaller and retry cheaper.
    public static let maxChunkSeconds: Double = 1320
    /// How many chunk uploads may be in flight at once.
    ///
    /// This used to be unbounded: a three-hour meeting fired every chunk into
    /// one task group simultaneously, and the resident payloads alone were
    /// enough for iOS to jetsam the app. Two keeps the upload pipe busy without
    /// letting peak memory scale with recording length.
    public static let maxConcurrentUploads = 2
    /// Last-resort language when the caller passes no hint. Whisper drifts into
    /// hallucinated English on Korean audio when it has to guess.
    public static let fallbackLanguage = "ko"
    /// Copy granularity when streaming audio into the multipart file.
    private static let copyBufferBytes = 1 << 20

    private let apiKey: String
    private let model: String
    private let endpoint: URL
    private let urlSession: URLSession

    public init(
        apiKey: String,
        model: String = "whisper-1",
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

        let boundary = "arca-\(UUID().uuidString)"

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        // Server-side transcription of a ~20-minute chunk can take several
        // minutes — the default 60s (and curl's old 120s cap) cut it off.
        request.timeoutInterval = 600
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        // Streamed to disk, never assembled in memory — see writeMultipartFile.
        let bodyFile = try Self.writeMultipartFile(
            boundary: boundary,
            audioURL: fileURL,
            model: model,
            language: Self.resolvedLanguage(hints),
            prompt: Self.promptHint(hints)
        )
        defer { try? FileManager.default.removeItem(at: bodyFile) }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await uploadFile(urlSession, for: request, bodyFile: bodyFile)
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
    /// and the upload-size caps, transcribes them a few at a time, and stitches
    /// the segments back together with each chunk's start-time offset.
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

        // Uploaded in small batches rather than all at once: peak memory and
        // peak socket count then depend on `maxConcurrentUploads`, not on how
        // long the meeting was.
        var pieces: [(Int, Double, Transcript)] = []
        for start in stride(from: 0, to: chunks.count, by: Self.maxConcurrentUploads) {
            let batch = chunks[start..<min(start + Self.maxConcurrentUploads, chunks.count)]
            let done = try await withThrowingTaskGroup(
                of: (Int, Double, Transcript).self
            ) { group in
                for chunk in batch {
                    group.addTask {
                        let transcript = try await transcribeSingle(
                            fileURL: chunk.url, channel: channel, hints: hints)
                        return (chunk.index, chunk.start, transcript)
                    }
                }
                var collected: [(Int, Double, Transcript)] = []
                for try await piece in group { collected.append(piece) }
                return collected
            }
            pieces.append(contentsOf: done)
        }
        pieces.sort { $0.0 < $1.0 }

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

    /// The language actually sent. Whisper's failure mode without a hint is not
    /// a worse guess but a different language entirely, so there is always one.
    public static func resolvedLanguage(_ hints: TranscriptHints) -> String {
        let hint = hints.languageCodes.first?.trimmingCharacters(in: .whitespaces) ?? ""
        return hint.isEmpty ? fallbackLanguage : hint
    }

    /// Attendee names and jargon, handed to whisper as a decoding prompt so it
    /// spells them the way the meeting does. These were already collected for
    /// this purpose and then dropped on the floor. Whisper only reads ~224
    /// tokens of prompt, so the list is truncated rather than sent whole.
    public static func promptHint(_ hints: TranscriptHints) -> String? {
        let vocabulary = hints.vocabulary
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !vocabulary.isEmpty else { return nil }
        return String(vocabulary.joined(separator: ", ").prefix(400))
    }

    /// Form fields sent alongside the audio part.
    ///
    /// `temperature=0` matters as much as the model choice: sampling is what
    /// produces whisper's repetition loops on quiet passages.
    public static func formFields(model: String, language: String, prompt: String?) -> [(String, String)] {
        var fields: [(String, String)] = [
            ("model", model),
            ("response_format", "verbose_json"),
            ("temperature", "0"),
            ("language", language),
        ]
        if let prompt, !prompt.isEmpty {
            fields.append(("prompt", prompt))
        }
        return fields
    }

    /// Writes the whole multipart payload to a temp file and returns its URL.
    /// The caller owns the file and must delete it.
    ///
    /// The audio is copied through a 1MB window instead of being loaded with
    /// `Data(contentsOf:)` and then copied again into a `Data` body. Those two
    /// copies plus URLSession's own made a multi-hour recording cost ~2.5× the
    /// file size in RAM at the moment of upload, which is what iOS was killing
    /// the app for. Peak is now one buffer, and the payload lives on disk.
    public static func writeMultipartFile(
        boundary: String,
        audioURL: URL,
        model: String,
        language: String,
        prompt: String?
    ) throws -> URL {
        let fileName = audioURL.lastPathComponent
        var prologue = Data()
        for (name, value) in formFields(model: model, language: language, prompt: prompt) {
            prologue.appendString("--\(boundary)\r\n")
            prologue.appendString("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            prologue.appendString("\(value)\r\n")
        }
        prologue.appendString("--\(boundary)\r\n")
        prologue.appendString("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n")
        prologue.appendString("Content-Type: \(mimeType(for: fileName))\r\n\r\n")

        var epilogue = Data()
        epilogue.appendString("\r\n--\(boundary)--\r\n")

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("arca-upload-\(UUID().uuidString).multipart")
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw OpenAITranscriptionError.chunking("Could not open a temporary file for the upload body.")
        }
        do {
            let output = try FileHandle(forWritingTo: destination)
            defer { try? output.close() }
            let input = try FileHandle(forReadingFrom: audioURL)
            defer { try? input.close() }

            try output.write(contentsOf: prologue)
            while let chunk = try input.read(upToCount: copyBufferBytes), !chunk.isEmpty {
                try output.write(contentsOf: chunk)
            }
            try output.write(contentsOf: epilogue)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        return destination
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

    /// A top-level object with a `segments` array; each segment carries
    /// `start`, `end`, `text`, and — only from a diarizing model — `speaker`.
    /// Whisper's `verbose_json` and the diarized shape agree on everything
    /// else, so one decoder covers both and a missing speaker just means the
    /// channel has a single voice.
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
