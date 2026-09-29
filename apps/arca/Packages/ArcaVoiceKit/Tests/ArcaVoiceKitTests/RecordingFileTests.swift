import Testing
import Foundation
import AVFoundation
@testable import Capture
import ArcaVoiceCore

/// The recording file must survive the process dying at any moment, and the
/// compaction that follows must never be the thing that loses it.
@Suite struct RecordingFileTests {
    private func tempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("arca-rec-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 48 kHz like an iPhone mic, so the writer's resampling is exercised too.
    private func micBuffer(seconds: Double, rate: Double = 48_000) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let frames = AVAudioFrameCount(seconds * rate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let samples = buffer.floatChannelData![0]
        for i in 0..<Int(frames) { samples[i] = sin(Float(i) * 0.03) * 0.4 }
        return buffer
    }

    private func seconds(_ url: URL) throws -> Double {
        let file = try AVAudioFile(forReading: url)
        return Double(file.length) / file.processingFormat.sampleRate
    }

    @Test func aRecordingKilledMidWriteIsStillReadable() throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = micBuffer(seconds: 0.1)
        let writer = try ChannelWriter(channel: .microphone, directory: dir, sourceFormat: source.format)
        for _ in 0..<60 { _ = writer.write(micBuffer(seconds: 0.1)) }   // 6 s

        // What a kill leaves behind: the bytes on disk while the writer is open.
        let snapshot = dir.appendingPathComponent("killed.caf")
        try FileManager.default.copyItem(at: writer.fileURL, to: snapshot)
        let recovered = try seconds(snapshot)
        #expect(recovered > 5.5, "a kill kept only \(recovered)s of 6s")

        writer.close()
        #expect(abs(try seconds(writer.fileURL) - 6) < 0.05)
    }

    @Test func aHalfWrittenFrameIsTrimmed() throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let writer = try ChannelWriter(channel: .microphone, directory: dir, sourceFormat: micBuffer(seconds: 0.1).format)
        for _ in 0..<20 { _ = writer.write(micBuffer(seconds: 0.1)) }
        let snapshot = dir.appendingPathComponent("torn.caf")
        try FileManager.default.copyItem(at: writer.fileURL, to: snapshot)
        writer.close()
        // A kill mid-write: one byte of a two-byte sample.
        let handle = try FileHandle(forWritingTo: snapshot)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0x7f]))
        try handle.close()
        let before = try FileManager.default.attributesOfItem(atPath: snapshot.path)[.size] as! Int

        AudioFinalizer.repairTruncatedTail(snapshot)

        let after = try FileManager.default.attributesOfItem(atPath: snapshot.path)[.size] as! Int
        #expect(after == before - 1)
        #expect(try seconds(snapshot) > 1.8)
    }

    @Test func compactionProducesAVerifiedM4aAndLeavesTheOriginal() throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let writer = try ChannelWriter(channel: .microphone, directory: dir, sourceFormat: micBuffer(seconds: 0.1).format)
        for _ in 0..<50 { _ = writer.write(micBuffer(seconds: 0.1)) }   // 5 s
        writer.close()

        let m4a = try AudioFinalizer.compact(writer.fileURL)

        #expect(m4a.pathExtension == "m4a")
        #expect(abs(try seconds(m4a) - 5) < 0.5)
        #expect(FileManager.default.fileExists(atPath: writer.fileURL.path), "the CAF is the caller's to delete")
        #expect(!FileManager.default.fileExists(atPath: m4a.appendingPathExtension("partial").path))
        let cafBytes = try FileManager.default.attributesOfItem(atPath: writer.fileURL.path)[.size] as! Int
        let m4aBytes = try FileManager.default.attributesOfItem(atPath: m4a.path)[.size] as! Int
        #expect(m4aBytes * 4 < cafBytes, "compaction should shrink the file")
    }

    @Test func compactionOfACrashLeftoverWorks() throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let writer = try ChannelWriter(channel: .microphone, directory: dir, sourceFormat: micBuffer(seconds: 0.1).format)
        for _ in 0..<30 { _ = writer.write(micBuffer(seconds: 0.1)) }
        let killed = dir.appendingPathComponent("microphone-killed.caf")
        try FileManager.default.copyItem(at: writer.fileURL, to: killed)
        writer.close()

        let m4a = try AudioFinalizer.compact(killed)
        #expect(try seconds(m4a) > 2.5)
    }

    @Test func anUnreadableFileIsReportedNotReplaced() throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let junk = dir.appendingPathComponent("microphone.caf")
        try Data(repeating: 0, count: 10_000).write(to: junk)
        let existing = AudioFinalizer.compactedURL(for: junk)
        try Data("keep me".utf8).write(to: existing)

        #expect(throws: (any Error).self) { try AudioFinalizer.compact(junk) }
        #expect(try String(contentsOf: existing, encoding: .utf8) == "keep me")
    }
}
