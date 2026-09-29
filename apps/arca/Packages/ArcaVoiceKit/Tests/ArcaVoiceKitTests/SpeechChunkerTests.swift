import Testing
import Foundation
import AVFoundation
@testable import Transcribe

@Suite struct SpeechChunkerTests {
    /// Writes a 16 kHz CAF: tone everywhere except the given silent spans.
    private func makeAudio(seconds: Double, silences: [ClosedRange<Double>] = []) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("arca-chunk-src-\(UUID().uuidString).caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = Int(seconds * 16_000)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        let samples = buffer.floatChannelData![0]
        for i in 0..<frames {
            let t = Double(i) / 16_000
            samples[i] = silences.contains { $0.contains(t) } ? 0 : sin(Float(i) * 0.07) * 0.3
        }
        try file.write(from: buffer)
        return url
    }

    private func outDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("arca-chunks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func cutsLandInThePause() throws {
        let source = try makeAudio(seconds: 25, silences: [11.5...12.5])
        let dir = try outDir()
        defer { try? FileManager.default.removeItem(at: dir); try? FileManager.default.removeItem(at: source) }

        let chunks = try SpeechChunker.export(source, into: dir, target: 10, maxExtension: 4)

        #expect(chunks.count == 2)
        #expect((11.5...12.5).contains(chunks[1].start), "cut at \(chunks[1].start)s, outside the pause")
        #expect(abs(chunks.reduce(0) { $0 + $1.duration } - 25) < 0.01)
        #expect(abs(chunks[1].start - chunks[0].duration) < 0.001)
    }

    @Test func withNoPauseTheCutStillHappensWithinTheExtension() throws {
        let source = try makeAudio(seconds: 30)
        let dir = try outDir()
        defer { try? FileManager.default.removeItem(at: dir); try? FileManager.default.removeItem(at: source) }

        let chunks = try SpeechChunker.export(source, into: dir, target: 10, maxExtension: 4)

        #expect(chunks.count >= 2)
        for chunk in chunks.dropLast() { #expect(chunk.duration <= 14.01) }
        #expect(abs(chunks.reduce(0) { $0 + $1.duration } - 30) < 0.01)
        // Every chunk is a real, readable m4a of the length it claims.
        for chunk in chunks {
            let file = try AVAudioFile(forReading: chunk.url)
            let fileSeconds = Double(file.length) / file.processingFormat.sampleRate
            #expect(abs(fileSeconds - SpeechChunker.leadIn - chunk.duration) < 0.1)
        }
    }

    @Test func fiveMinuteChunksFitUnderTheProxyLimit() throws {
        let source = try makeAudio(seconds: 330)
        let dir = try outDir()
        defer { try? FileManager.default.removeItem(at: dir); try? FileManager.default.removeItem(at: source) }

        let chunks = try SpeechChunker.export(source, into: dir)

        let biggest = try chunks.map { try FileManager.default.attributesOfItem(atPath: $0.url.path)[.size] as! Int }.max()!
        #expect(biggest < 3 * 1024 * 1024, "a chunk is \(biggest) bytes; Vercel refuses bodies over 4.5 MB")
    }

    @Test func leadInIsTakenBackOutOfTimestamps() {
        let chunk = SpeechChunker.Chunk(index: 1, start: 300, duration: 290, url: URL(fileURLWithPath: "/x"))
        #expect(SpeechChunker.recordingTime(0.5, in: chunk) == 300)
        #expect(SpeechChunker.recordingTime(10.5, in: chunk) == 310)
        #expect(SpeechChunker.recordingTime(0, in: chunk) == 300, "never earlier than the chunk")
    }

    @Test func aShortRecordingIsOneChunk() throws {
        let source = try makeAudio(seconds: 3)
        let dir = try outDir()
        defer { try? FileManager.default.removeItem(at: dir); try? FileManager.default.removeItem(at: source) }
        let chunks = try SpeechChunker.export(source, into: dir)
        #expect(chunks.count == 1)
        #expect(chunks[0].start == 0)
    }
}

@Suite struct SpeechGapsTests {
    /// 0.25 s windows: a Korean line, nine seconds of English the hinted pass
    /// skipped, then Korean again — the shape measured on a real mixed meeting.
    private func loudness(_ spans: [(Double, Double)], total: Double, quiet: Float = 0.002, loud: Float = 0.1) -> [Float] {
        (0..<Int(total * 4)).map { index in
            let t = (Double(index) + 0.5) / 4
            return spans.contains { $0.0 <= t && t < $0.1 } ? loud : quiet
        }
    }

    @Test func findsTheSpeechTheTranscriptSkipped() throws {
        let rms = loudness([(1, 12), (12.7, 21.8), (22, 34)], total: 36)
        let regions = SpeechGaps.regions(windowRMS: rms, windowSeconds: 0.25,
                                         covered: [1...6, 6...12, 22...27, 27...34])
        try #require(regions.count == 1)
        #expect(regions[0].lowerBound >= 12.5 && regions[0].lowerBound <= 13)
        #expect(regions[0].upperBound >= 21 && regions[0].upperBound <= 22)
    }

    @Test func aFullyCoveredChunkHasNoGaps() {
        let rms = loudness([(0, 30)], total: 30)
        #expect(SpeechGaps.regions(windowRMS: rms, windowSeconds: 0.25, covered: [0...30]).isEmpty)
    }

    @Test func aCoughIsNotAGap() {
        let rms = loudness([(10, 10.75)], total: 20)
        #expect(SpeechGaps.regions(windowRMS: rms, windowSeconds: 0.25, covered: []).isEmpty)
    }

    @Test func pausesBetweenWordsDoNotSplitAGap() {
        let rms = loudness([(5, 6), (6.5, 7.5), (8, 9)], total: 12)
        let regions = SpeechGaps.regions(windowRMS: rms, windowSeconds: 0.25, covered: [])
        #expect(regions.count == 1)
    }

    @Test func aNoisyRoomRaisesTheBar() {
        // Constant hum well above the absolute floor is not speech.
        let rms = [Float](repeating: 0.03, count: 120)
        #expect(SpeechGaps.regions(windowRMS: rms, windowSeconds: 0.25, covered: []).isEmpty)
    }

    @Test func chunksCarryTheirLoudness() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("arca-rms-\(UUID().uuidString).caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32_000)!
        buffer.frameLength = 32_000
        for i in 0..<32_000 { buffer.floatChannelData![0][i] = i < 16_000 ? 0 : sin(Float(i) * 0.07) * 0.3 }
        try file.write(from: buffer)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("arca-rms-out-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir); try? FileManager.default.removeItem(at: url) }

        let chunks = try SpeechChunker.export(url, into: dir)

        #expect(chunks[0].windowRMS.count == 8)
        #expect(chunks[0].windowRMS[0] < 0.001)
        #expect(chunks[0].windowRMS[7] > 0.1)
    }

    @Test func clipsCanBeCutOutOfAChunk() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("arca-clip-\(UUID().uuidString).caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160_000)!
        buffer.frameLength = 160_000
        for i in 0..<160_000 { buffer.floatChannelData![0][i] = sin(Float(i) * 0.07) * 0.3 }
        try file.write(from: buffer)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("arca-clip-out-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir); try? FileManager.default.removeItem(at: url) }
        let chunk = try SpeechChunker.export(url, into: dir)[0]

        let clip = dir.appendingPathComponent("clip.m4a")
        try SpeechChunker.extractClip(from: chunk, start: 2, end: 5, to: clip)

        let read = try AVAudioFile(forReading: clip)
        let seconds = Double(read.length) / read.processingFormat.sampleRate
        #expect(abs(seconds - (3 + SpeechChunker.leadIn)) < 0.1)
    }
}
