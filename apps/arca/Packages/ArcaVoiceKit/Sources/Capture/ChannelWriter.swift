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
        // AAC only encodes the standard rates — pro interfaces (96k+) and
        // odd aggregate-device rates otherwise kill file creation with '!dat'.
        // The converter resamples buffers to the file rate, so clamping is safe.
        let aacRates: [Double] = [8000, 11025, 12000, 16000, 22050, 24000, 32000, 44100, 48000]
        let fileRate = aacRates.contains(sourceFormat.sampleRate) ? sourceFormat.sampleRate : 48000
        // The encoder rejects bitrates outside the valid range for the
        // rate/channel combo (96kbps @16kHz mono = '!dat') — scale it.
        let bitRate = min(96_000, Int(fileRate) * 2) * Int(channelCount)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: fileRate,
            AVNumberOfChannelsKey: channelCount,
            AVEncoderBitRateKey: bitRate,
        ]
        do {
            self.file = try AVAudioFile(forWriting: fileURL, settings: settings,
                                        commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch {
            throw CaptureError.fileCreationFailed(error.localizedDescription)
        }
        // Elapsed counts frames written at the FILE rate, not the source rate.
        self.sampleRate = fileRate
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
