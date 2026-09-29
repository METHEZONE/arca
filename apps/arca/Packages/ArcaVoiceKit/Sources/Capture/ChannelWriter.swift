import Foundation
import AVFoundation
import ArcaVoiceCore

/// Writes one channel's buffers to a crash-safe recording file and tracks
/// elapsed time via frame counting. Confine calls to a single queue per instance.
///
/// The file is 16 kHz mono 16-bit PCM in a CAF container, not AAC in an m4a.
/// An m4a only becomes readable when its `moov` box is written at close, so a
/// kill, a crash, or iOS reclaiming memory mid-meeting used to leave a file
/// nothing could open — the whole recording gone. CoreAudio writes a CAF's data
/// chunk with size -1 ("runs to end of file") while recording, so whatever
/// reached disk is playable no matter how the process ends
/// (`RecordingFileTests` snapshots a file mid-write to prove it).
/// `AudioFinalizer` turns it into a compact m4a after the recording is safe.
final class ChannelWriter: @unchecked Sendable {
    /// Speech needs no more: the transcribers resample to 16 kHz anyway, and it
    /// keeps the uncompressed file at ~115 MB an hour until it's compacted.
    static let fileSampleRate: Double = 16_000

    let channel: CaptureChannel
    let fileURL: URL
    private var file: AVAudioFile?
    private let processingFormat: AVAudioFormat
    private let converter = BufferConverter()
    private var framesWritten: AVAudioFramePosition = 0
    /// Set once a write fails (disk full, file yanked). Surfaced so the
    /// recording UI can stop claiming to record over nothing.
    private(set) var writeError: Error?
    /// `write` runs on the audio thread and `close` on whoever stops the
    /// recording; a buffer landing mid-close must not touch a closed file.
    private let lock = NSLock()

    init(channel: CaptureChannel, directory: URL, sourceFormat: AVAudioFormat) throws {
        self.channel = channel
        self.fileURL = directory.appendingPathComponent("\(channel.rawValue).caf")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Self.fileSampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        do {
            let file = try AVAudioFile(forWriting: fileURL, settings: settings,
                                       commonFormat: .pcmFormatFloat32, interleaved: false)
            self.file = file
            self.processingFormat = file.processingFormat
        } catch {
            throw CaptureError.fileCreationFailed(error.localizedDescription)
        }
    }

    var elapsed: TimeInterval {
        Double(framesWritten) / Self.fileSampleRate
    }

    /// Writes the buffer and returns it converted to the file's processing
    /// format, stamped with the pre-write elapsed time, ready for the live pipeline.
    func write(_ buffer: AVAudioPCMBuffer) -> CapturedBuffer? {
        lock.lock()
        defer { lock.unlock() }
        guard let file else { return nil }
        let startTime = elapsed
        let converted: AVAudioPCMBuffer
        do {
            converted = try converter.convert(buffer, to: processingFormat)
        } catch {
            return nil
        }
        do {
            try file.write(from: converted)
            framesWritten += AVAudioFramePosition(converted.frameLength)
            writeError = nil
        } catch {
            writeError = error
        }
        // Still handed to the live transcriber: the words on screen are worth
        // keeping even while the disk refuses the audio.
        return CapturedBuffer(channel: channel, buffer: converted, elapsed: startTime)
    }

    /// Flushes and closes the file. Idempotent. Must run before anything reads
    /// the file back — an open writer can still be holding the tail in memory.
    func close() {
        lock.lock()
        defer { lock.unlock() }
        file?.close()
        file = nil
    }
}
