import Foundation
import AVFoundation
import ArcaVoiceCore

/// Cuts a recording into upload-sized speech chunks, at quiet moments.
///
/// Every cloud upload goes through here, whatever the recording's length or
/// format (a crash-safe CAF included):
/// - Small requests. ARCA Cloud's proxy runs on Vercel, which refuses request
///   bodies over 4.5 MB; five minutes of 16 kHz mono AAC at 32 kbps is ~1.2 MB.
///   A failed chunk also retries in seconds instead of re-sending an hour.
/// - Cuts land in pauses, not mid-word. After the target length the chunker
///   keeps listening for up to `maxExtension` and cuts in the first near-silent
///   quarter second — or the quietest one it heard — so a boundary never eats
///   the syllable a fixed cut would have split.
/// - Every chunk opens with `leadIn` of silence. Whisper given a prompt drops
///   the first word of audio that starts mid-speech — measured: "민성씨, 다음
///   주…" came back as "다음 주…", and half a second of silence brought the
///   name back. The pad is not counted in `start`/`duration`; `recordingTime(_:in:)`
///   takes it back out of the timestamps.
/// - Offsets are counted in samples written, so stitched timestamps are exact.
enum SpeechChunker {
    struct Chunk: Sendable {
        let index: Int
        let start: TimeInterval
        let duration: TimeInterval
        let url: URL
        /// Loudness of each `windowSamples` window of the chunk's audio (lead-in
        /// excluded) — how `SpeechGaps` finds speech the transcript skipped.
        var windowRMS: [Float] = []
    }

    static var windowSeconds: TimeInterval { Double(windowSamples) / sampleRate }

    static let sampleRate: Double = 16_000
    static let leadIn: TimeInterval = 0.5

    /// Maps a time inside a chunk file to a time in the recording.
    static func recordingTime(_ chunkTime: TimeInterval, in chunk: Chunk) -> TimeInterval {
        max(chunk.start, chunk.start + chunkTime - leadIn)
    }
    /// Quarter-second windows for finding a pause.
    static let windowSamples = 4_000
    /// ≈ -50 dBFS: a pause between words in any real room clears this.
    static let silenceFloor: Float = 0.003

    static var aacSettings: [String: Any] { [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 16_000,
        AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey: 32_000,
    ] }

    static func export(_ source: URL, into directory: URL,
                       target: TimeInterval = 300,
                       maxExtension: TimeInterval = 30) throws -> [Chunk] {
        let file = try AVAudioFile(forReading: source)
        guard file.length > 0 else { return [] }
        guard let speechFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                               channels: 1, interleaved: false),
              let readBuffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16_384) else {
            throw BufferConverter.ConversionError.bufferAllocationFailed
        }
        let converter = BufferConverter()
        var writer = ChunkWriter(directory: directory, format: speechFormat,
                                 targetSamples: Int(target * sampleRate),
                                 maxTailSamples: Int(maxExtension * sampleRate))
        while file.framePosition < file.length {
            try file.read(into: readBuffer, frameCount: readBuffer.frameCapacity)
            guard readBuffer.frameLength > 0 else { break }
            let speech = try converter.convert(readBuffer, to: speechFormat)
            guard let samples = speech.floatChannelData?[0] else { continue }
            try writer.append(UnsafeBufferPointer(start: samples, count: Int(speech.frameLength)))
        }
        return try writer.finish()
    }

    /// Cuts `[start, end)` (chunk time, lead-in excluded) out of a chunk into
    /// its own file, with the same lead-in every chunk gets.
    static func extractClip(from chunk: Chunk, start: TimeInterval, end: TimeInterval, to url: URL) throws {
        let source = try AVAudioFile(forReading: chunk.url)
        let rate = source.processingFormat.sampleRate
        let first = AVAudioFramePosition((leadIn + max(0, start)) * rate)
        let count = AVAudioFrameCount(max(0, min(Double(source.length - first), (end - start) * rate)))
        guard count > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: count),
              let pad = AVAudioPCMBuffer(pcmFormat: source.processingFormat,
                                         frameCapacity: AVAudioFrameCount(leadIn * rate)) else {
            throw BufferConverter.ConversionError.bufferAllocationFailed
        }
        source.framePosition = first
        try source.read(into: buffer, frameCount: count)
        pad.frameLength = pad.frameCapacity
        let output = try AVAudioFile(forWriting: url, settings: aacSettings,
                                     commonFormat: .pcmFormatFloat32, interleaved: false)
        try output.write(from: pad)
        try output.write(from: buffer)
        output.close()
    }

    /// Streams samples into chunk files, holding back only the tail that is
    /// still a candidate for the cut.
    private struct ChunkWriter {
        let directory: URL
        let format: AVAudioFormat
        let targetSamples: Int
        let maxTailSamples: Int

        private var chunks: [Chunk] = []
        private var current: AVAudioFile?
        private var currentURL: URL?
        private var currentStart = 0
        private var currentSamples = 0
        private var tail: [Float] = []
        private var windowRMS: [Float] = []
        private var windowPower: Float = 0
        private var windowFill = 0

        init(directory: URL, format: AVAudioFormat, targetSamples: Int, maxTailSamples: Int) {
            self.directory = directory
            self.format = format
            self.targetSamples = targetSamples
            self.maxTailSamples = maxTailSamples
        }

        mutating func append(_ samples: UnsafeBufferPointer<Float>) throws {
            var offset = 0
            // Up to the target, straight into the file.
            if currentSamples < targetSamples {
                let direct = min(samples.count, targetSamples - currentSamples)
                try write(Array(samples[0..<direct]))
                offset = direct
            }
            guard offset < samples.count else { return }
            tail.append(contentsOf: samples[offset...])
            try cutIfReady()
        }

        /// Looks through the complete windows of the tail for a pause.
        private mutating func cutIfReady() throws {
            let windows = tail.count / SpeechChunker.windowSamples
            var quietest: (index: Int, rms: Float)?
            for window in 0..<windows {
                let rms = Self.rms(tail, window: window)
                if rms < SpeechChunker.silenceFloor {
                    try cut(at: window * SpeechChunker.windowSamples + SpeechChunker.windowSamples / 2)
                    return
                }
                if quietest == nil || rms < quietest!.rms { quietest = (window, rms) }
            }
            if tail.count >= maxTailSamples, let quietest {
                try cut(at: quietest.index * SpeechChunker.windowSamples + SpeechChunker.windowSamples / 2)
            }
        }

        private static func rms(_ samples: [Float], window: Int) -> Float {
            let range = window * SpeechChunker.windowSamples..<(window + 1) * SpeechChunker.windowSamples
            let power = samples[range].reduce(Float(0)) { $0 + $1 * $1 }
            return (power / Float(SpeechChunker.windowSamples)).squareRoot()
        }

        private mutating func cut(at index: Int) throws {
            let rest = Array(tail[index...])
            try write(Array(tail[0..<index]))
            tail = []
            closeCurrent()
            try write(rest)
        }

        private mutating func write(_ samples: [Float]) throws {
            guard !samples.isEmpty else { return }
            if current == nil {
                let url = directory.appendingPathComponent("chunk-\(chunks.count).m4a")
                let file = try AVAudioFile(forWriting: url, settings: SpeechChunker.aacSettings,
                                           commonFormat: .pcmFormatFloat32, interleaved: false)
                let padFrames = AVAudioFrameCount(SpeechChunker.leadIn * SpeechChunker.sampleRate)
                if let pad = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: padFrames) {
                    pad.frameLength = padFrames   // zero-filled
                    try file.write(from: pad)
                }
                current = file
                currentURL = url
            }
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                                frameCapacity: AVAudioFrameCount(samples.count)) else {
                throw BufferConverter.ConversionError.bufferAllocationFailed
            }
            buffer.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { source in
                buffer.floatChannelData![0].update(from: source.baseAddress!, count: samples.count)
            }
            try current!.write(from: buffer)
            currentSamples += samples.count
            for sample in samples {
                windowPower += sample * sample
                windowFill += 1
                if windowFill == SpeechChunker.windowSamples { flushWindow() }
            }
        }

        private mutating func flushWindow() {
            guard windowFill > 0 else { return }
            windowRMS.append((windowPower / Float(windowFill)).squareRoot())
            windowPower = 0
            windowFill = 0
        }

        private mutating func closeCurrent() {
            guard let file = current, let url = currentURL else { return }
            file.close()
            flushWindow()
            chunks.append(Chunk(index: chunks.count,
                                start: Double(currentStart) / SpeechChunker.sampleRate,
                                duration: Double(currentSamples) / SpeechChunker.sampleRate,
                                url: url,
                                windowRMS: windowRMS))
            windowRMS = []
            currentStart += currentSamples
            currentSamples = 0
            current = nil
            currentURL = nil
        }

        mutating func finish() throws -> [Chunk] {
            try write(tail)
            tail = []
            closeCurrent()
            return chunks
        }
    }
}
