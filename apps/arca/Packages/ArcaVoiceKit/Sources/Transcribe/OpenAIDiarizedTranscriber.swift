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
/// Every recording is cut by `SpeechChunker` into ~5-minute chunks at pauses,
/// transcribed a few at a time — each retried on its own when the network
/// hiccups — and stitched back together with sample-exact offsets.
///
/// Two ways in: the user's own OpenAI key straight to OpenAI, or ARCA Cloud
/// (`app/api/arca/transcribe`) with the tester's invite code, which is how the
/// beta gets cloud accuracy without anyone owning a key.
public struct OpenAIDiarizedTranscriber: FinalTranscriber {
    public enum Auth: Sendable {
        /// `Authorization: Bearer <OpenAI key>`.
        case openAIKey
        /// `x-api-key: <invite code>` — ARCA Cloud's own check.
        case arcaCloud
    }

    /// How many chunk uploads may be in flight at once. Bounded so peak memory
    /// and socket count don't grow with the length of the meeting.
    public static let maxConcurrentUploads = 3
    /// Last-resort language when the caller passes no hint. Whisper drifts into
    /// hallucinated English on Korean audio when it has to guess.
    public static let fallbackLanguage = "ko"
    /// Copy granularity when streaming audio into the multipart file.
    private static let copyBufferBytes = 1 << 20
    /// Waits between attempts at one chunk. Four retries ride out a tunnel, a
    /// provider blip, or a rate limit; a chunk that still fails fails the pass,
    /// which keeps the recording queued for the next sweep.
    static let retryDelays: [Duration] = [.seconds(2), .seconds(6), .seconds(15), .seconds(30)]

    private let apiKey: String
    private let model: String
    private let endpoint: URL
    private let auth: Auth
    private let urlSession: URLSession

    public init(
        apiKey: String,
        model: String = "whisper-1",
        endpoint: URL = URL(string: "https://api.openai.com/v1/audio/transcriptions")!,
        auth: Auth = .openAIKey,
        urlSession: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.model = model
        self.endpoint = endpoint
        self.auth = auth
        self.urlSession = urlSession
    }

    public func transcribe(fileURL: URL, channel: CaptureChannel, hints: TranscriptHints) async throws -> Transcript {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("arca-chunks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let chunks: [SpeechChunker.Chunk]
        do {
            chunks = try SpeechChunker.export(fileURL, into: tempDir)
        } catch {
            throw OpenAITranscriptionError.chunking(error.localizedDescription)
        }

        var pieces: [(chunk: SpeechChunker.Chunk, transcript: Transcript)] = []
        for batchStart in stride(from: 0, to: chunks.count, by: Self.maxConcurrentUploads) {
            let batch = chunks[batchStart..<min(batchStart + Self.maxConcurrentUploads, chunks.count)]
            let done = try await withThrowingTaskGroup(of: (SpeechChunker.Chunk, Transcript).self) { group in
                for chunk in batch {
                    group.addTask {
                        var transcript = try await withTransientRetry(delays: Self.retryDelays) {
                            try await transcribeSingle(fileURL: chunk.url, channel: channel,
                                                       language: Self.resolvedLanguage(hints),
                                                       prompt: Self.promptHint(hints),
                                                       seconds: chunk.duration)
                        }
                        transcript.segments = await fillGaps(in: transcript.segments, chunk: chunk,
                                                             channel: channel)
                        return (chunk, transcript)
                    }
                }
                var collected: [(SpeechChunker.Chunk, Transcript)] = []
                for try await piece in group { collected.append(piece) }
                return collected
            }
            pieces.append(contentsOf: done.sorted { $0.0.index < $1.0.index }.map { ($0.0, $0.1) })
        }

        var segments: [Transcript.Segment] = []
        for piece in pieces {
            for segment in piece.transcript.segments {
                let start = SpeechChunker.recordingTime(segment.start, in: piece.chunk)
                segments.append(Transcript.Segment(
                    text: segment.text,
                    start: start,
                    end: max(start, SpeechChunker.recordingTime(segment.end, in: piece.chunk)),
                    confidence: segment.confidence,
                    speakerLabel: segment.speakerLabel))
            }
        }
        let language = pieces.first { !($0.transcript.languageCode ?? "").isEmpty }?.transcript.languageCode
        // Logged once per channel with the whole duration, not per chunk —
        // billing follows the audio, so counting chunks would inflate it.
        AIUsageLog.appendAudio(provider: auth == .arcaCloud ? "arca-cloud" : "openai", model: model,
                               source: "transcribe-\(channel.rawValue)",
                               seconds: chunks.reduce(0) { $0 + $1.duration })
        return Transcript(channel: channel, segments: segments, languageCode: language)
    }

    /// Re-transcribes, with no language hint, the stretches of `chunk` where
    /// there was speech and the hinted pass returned nothing (see
    /// `SpeechGaps`). Best-effort: a gap that fails stays a gap, the chunk's
    /// own transcript is never put at risk. Segments are in chunk-file time,
    /// like the ones they join.
    private func fillGaps(in segments: [Transcript.Segment], chunk: SpeechChunker.Chunk,
                          channel: CaptureChannel) async -> [Transcript.Segment] {
        let lead = SpeechChunker.leadIn
        let covered = segments.map { ($0.start - lead)...max($0.start - lead, $0.end - lead) }
        let regions = SpeechGaps.regions(windowRMS: chunk.windowRMS,
                                         windowSeconds: SpeechChunker.windowSeconds, covered: covered)
        guard !regions.isEmpty else { return segments }
        var result = segments
        // ponytail: a dozen per chunk bounds the extra requests on a noisy
        // recording; raise it if real meetings hit the cap.
        for (number, region) in regions.prefix(12).enumerated() {
            let clipStart = max(0, region.lowerBound - 0.3)
            let clipEnd = min(chunk.duration, region.upperBound + 0.3)
            let clip = chunk.url.deletingLastPathComponent()
                .appendingPathComponent("gap-\(chunk.index)-\(number).m4a")
            defer { try? FileManager.default.removeItem(at: clip) }
            guard (try? SpeechChunker.extractClip(from: chunk, start: clipStart, end: clipEnd, to: clip)) != nil,
                  let found = try? await withTransientRetry(delays: [.seconds(2), .seconds(6)], {
                      try await transcribeSingle(fileURL: clip, channel: channel, language: nil, prompt: nil,
                                                 seconds: clipEnd - clipStart)
                  }) else { continue }
            for segment in found.segments {
                let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                let start = clipStart + segment.start          // clip-file → chunk-file time
                let end = clipStart + segment.end
                let words = text.split(separator: " ").count
                guard !text.isEmpty,
                      end - start >= 0.6 || words >= 3,
                      start - lead <= region.upperBound,
                      !SpeechGaps.noisePhrases.contains(text.lowercased()),
                      !result.contains(where: { $0.text.contains(text) }) else { continue }
                result.append(Transcript.Segment(text: text, start: start, end: end,
                                                 confidence: segment.confidence,
                                                 speakerLabel: segment.speakerLabel))
            }
        }
        return result.sorted { $0.start < $1.start }
    }

    private func transcribeSingle(fileURL: URL, channel: CaptureChannel,
                                  language: String?, prompt: String?,
                                  seconds: TimeInterval) async throws -> Transcript {
        let boundary = "arca-\(UUID().uuidString)"

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        // A five-minute chunk normally comes back in 10–30 s. Whisper does
        // occasionally stall on one request (measured: 4 minutes for a clip
        // that took 3 s on the next try), and a retry is faster than waiting.
        request.timeoutInterval = 120
        switch auth {
        case .openAIKey: request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        case .arcaCloud: request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        }
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        // Streamed to disk, never assembled in memory — see writeMultipartFile.
        let bodyFile = try Self.writeMultipartFile(
            boundary: boundary,
            audioURL: fileURL,
            model: model,
            language: language,
            prompt: prompt,
            // ARCA Cloud defaults a missing language to Korean; "auto" is how
            // the gap pass asks it to detect instead.
            autoLanguageToken: auth == .arcaCloud ? "auto" : nil,
            // ARCA Cloud's usage record ("time spent with ARCA"); OpenAI
            // itself rejects fields it doesn't know.
            audioSeconds: auth == .arcaCloud ? seconds : nil
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
        var parts: [String] = []
        if !vocabulary.isEmpty {
            parts.append(String(vocabulary.joined(separator: ", ").prefix(300)))
        }
        // Whisper reads the prompt as the text that came before, and copies its
        // style. Korean meetings are full of English product words; a prompt
        // that already mixes the two keeps them in Latin letters instead of
        // turning "TestFlight" into "테스트 플라이트".
        if resolvedLanguage(hints) == "ko" {
            parts.append(koreanStyleSeed)
        }
        return parts.isEmpty ? nil : parts.joined(separator: ". ")
    }

    public static let koreanStyleSeed = "네, 그럼 다음 주 미팅 전에 TestFlight 빌드랑 API 문서 정리해서 Slack에 공유할게요."

    /// Form fields sent alongside the audio part.
    ///
    /// `temperature=0` matters as much as the model choice: sampling is what
    /// produces whisper's repetition loops on quiet passages.
    public static func formFields(model: String, language: String?, prompt: String?,
                                  autoLanguageToken: String? = nil,
                                  audioSeconds: TimeInterval? = nil) -> [(String, String)] {
        var fields: [(String, String)] = [
            ("model", model),
            ("response_format", "verbose_json"),
            ("temperature", "0"),
        ]
        if let language = language ?? autoLanguageToken {
            fields.append(("language", language))
        }
        if let audioSeconds {
            fields.append(("audioSeconds", String(format: "%.1f", audioSeconds)))
        }
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
        language: String?,
        prompt: String?,
        autoLanguageToken: String? = nil,
        audioSeconds: TimeInterval? = nil
    ) throws -> URL {
        let fileName = audioURL.lastPathComponent
        var prologue = Data()
        for (name, value) in formFields(model: model, language: language, prompt: prompt,
                                        autoLanguageToken: autoLanguageToken, audioSeconds: audioSeconds) {
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
        return Transcript(channel: channel, segments: dropHallucinatedRepeats(segments), languageCode: decoded.language)
    }

    // MARK: - Hallucination filtering

    /// Whisper-family models (this one included) hallucinate filler text on
    /// silence or low-energy audio — a lull in the conversation comes back as
    /// the same short phrase ("you", "감사합니다") repeated segment after
    /// segment at regular intervals, or as one segment whose text is a single
    /// phrase looping dozens of times. Neither pattern occurs in real speech,
    /// so both get collapsed to a single instance rather than spammed verbatim
    /// into the transcript and, from there, into the meeting summary.
    static func dropHallucinatedRepeats(_ segments: [Transcript.Segment]) -> [Transcript.Segment] {
        var result: [Transcript.Segment] = []
        var run: [Transcript.Segment] = []

        func flushRun() {
            guard let first = run.first else { return }
            if run.count >= 3 {
                // Keep one copy, spanning the whole run's time — the silence
                // happened, but there's no reason to say "you" nine times.
                var collapsed = first
                collapsed.end = run.last!.end
                result.append(collapsed)
            } else {
                result.append(contentsOf: run)
            }
            run.removeAll()
        }

        for rawSegment in segments {
            var segment = rawSegment
            segment.text = collapseInternalRepeat(segment.text)
            let normalized = segment.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let runNormalized = run.first?.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            // Same speaker too — two different speakers trading the same short
            // reply ("네" / "네") is a real exchange, not a hallucination loop.
            if !normalized.isEmpty, normalized == runNormalized, segment.speakerLabel == run.first?.speakerLabel {
                run.append(segment)
            } else {
                flushRun()
                run = [segment]
            }
        }
        flushRun()
        return result
    }

    /// A single segment can itself be a hallucination loop — the same short
    /// sentence repeated until the model's output budget runs out. Detect a
    /// sentence that accounts for at least half the segment and occurs 4+
    /// times, and collapse it to one copy.
    static func collapseInternalRepeat(_ text: String) -> String {
        let sentences = text
            .split(whereSeparator: { ".!?。".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard sentences.count >= 4 else { return text }

        var counts: [String: Int] = [:]
        for sentence in sentences { counts[sentence, default: 0] += 1 }
        guard let (phrase, count) = counts.max(by: { $0.value < $1.value }),
              count >= 4, count * 2 >= sentences.count else {
            return text
        }
        return phrase.hasSuffix(".") || phrase.hasSuffix("!") || phrase.hasSuffix("?") || phrase.hasSuffix("。")
            ? phrase : phrase + "."
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
}

/// LocalizedError conformance matters: FinalPassRunner stores
/// `error.localizedDescription`, which without it collapses to the useless
/// "(Transcribe.OpenAITranscriptionError error 2.)".
public enum OpenAITranscriptionError: Error, CustomStringConvertible, LocalizedError, TransientError {
    case transport(Error)
    case invalidResponse
    case api(status: Int, message: String)
    case decoding(Error)
    case chunking(String)

    public var description: String {
        switch self {
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

    public var isTransient: Bool {
        switch self {
        case .transport(let error): return isTransientTransportError(error)
        case .api(let status, _): return isTransientHTTPStatus(status)
        case .invalidResponse, .decoding, .chunking: return false
        }
    }
}

private extension Data {
    mutating func appendString(_ string: String) {
        if let data = string.data(using: .utf8) {
            append(data)
        }
    }
}
