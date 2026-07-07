import Foundation
import AVFoundation
import ArcaVoiceCore

/// Writes one channel's buffers to an AAC .m4a file and tracks elapsed time
/// via frame counting. Confine calls to a single queue per instance.
final class ChannelWriter: @unchecked Sendable {
    let channel: CaptureChannel
    let fileURL: URL
    private let file: AVAudioFile
    private let converter = BufferConverter()
    private var framesWritten: AVAudioFramePosition = 0
    private let sampleRate: Double

    init(channel: CaptureChannel, directory: URL, sourceFormat: AVAudioFormat) throws {
        self.channel = channel
        self.fileURL = directory.appendingPathComponent("\(channel.rawValue).m4a")

        let channelCount = min(sourceFormat.channelCount, 2)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sourceFormat.sampleRate,
            AVNumberOfChannelsKey: channelCount,
            AVEncoderBitRateKey: 96_000,
        ]
        do {
            self.file = try AVAudioFile(forWriting: fileURL, settings: settings,
                                        commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch {
            throw CaptureError.fileCreationFailed(error.localizedDescription)
        }
        self.sampleRate = sourceFormat.sampleRate
    }

    var elapsed: TimeInterval {
        Double(framesWritten) / sampleRate
    }

    /// Writes the buffer and returns it converted to the file's processing
    /// format, stamped with the pre-write elapsed time, ready for the live pipeline.
    func write(_ buffer: AVAudioPCMBuffer) -> CapturedBuffer? {
        let startTime = elapsed
        do {
            let converted = try converter.convert(buffer, to: file.processingFormat)
            try file.write(from: converted)
            framesWritten += AVAudioFramePosition(converted.frameLength)
            return CapturedBuffer(channel: channel, buffer: converted, elapsed: startTime)
        } catch {
            return nil
        }
    }
}
