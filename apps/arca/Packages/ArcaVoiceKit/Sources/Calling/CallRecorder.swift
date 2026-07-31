import Foundation
@preconcurrency import AVFoundation

/// Records both sides of a call to disk, as two separate tracks.
///
/// Separate tracks rather than a mix, because diarisation is then free: track
/// `me.m4a` is the user and `them.m4a` is the other party, with no speaker
/// clustering to get wrong. The existing transcribe pipeline already knows how to
/// merge two labelled channels.
///
/// Recording happens on-device, in our own audio graph, so there is no
/// notification tone, no server copy, and headphones do not break it.
public final class CallRecorder: @unchecked Sendable {
    public enum Track: String, Sendable, CaseIterable {
        case me
        case them
    }

    public let directory: URL
    private let queue = DispatchQueue(label: "com.thezone.arca.call.recorder")
    private var writers: [Track: AVAudioFile] = [:]
    private var frameCounts: [Track: AVAudioFramePosition] = [:]
    private let format: AVAudioFormat
    private var isFinished = false

    public init(directory: URL, format: AVAudioFormat) throws {
        self.directory = directory
        self.format = format
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // 48kHz mono AAC at 64kbps: a faithful record of a 40kbps call without
        // bloating storage. An hour lands around 28MB.
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: CallWire.sampleRate,
            AVNumberOfChannelsKey: Int(CallWire.channelCount),
            AVEncoderBitRateKey: 64_000,
        ]
        for track in Track.allCases {
            let url = directory.appendingPathComponent("\(track.rawValue).m4a")
            writers[track] = try AVAudioFile(forWriting: url, settings: settings,
                                             commonFormat: .pcmFormatFloat32, interleaved: false)
            frameCounts[track] = 0
        }
        CallTrace.log("recorder: writing to \(directory.lastPathComponent)")
    }

    public func append(_ buffer: AVAudioPCMBuffer, to track: Track) {
        queue.async { [weak self] in
            guard let self, !self.isFinished, let file = self.writers[track] else { return }
            do {
                try file.write(from: buffer)
                self.frameCounts[track, default: 0] += AVAudioFramePosition(buffer.frameLength)
            } catch {
                CallTrace.log("recorder: write failed on \(track.rawValue) — \(error)")
            }
        }
    }

    /// Writes `sampleCount` frames of silence into a track. Used when the far end
    /// drops packets, so both files stay aligned on a common timeline and the
    /// transcript timestamps still line up.
    public func appendSilence(sampleCount: Int, to track: Track) {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(sampleCount)),
              let channel = buffer.floatChannelData?[0] else { return }
        channel.update(repeating: 0, count: sampleCount)
        buffer.frameLength = AVAudioFrameCount(sampleCount)
        append(buffer, to: track)
    }

    public struct Result: Sendable {
        public let directory: URL
        public let trackURLs: [String: URL]
        public let duration: TimeInterval
    }

    public func finish() -> Result {
        queue.sync {
            isFinished = true
            writers.removeAll()
        }
        let longest = frameCounts.values.max() ?? 0
        let urls = Dictionary(uniqueKeysWithValues: Track.allCases.map {
            ($0.rawValue, directory.appendingPathComponent("\($0.rawValue).m4a"))
        })
        let duration = Double(longest) / CallWire.sampleRate
        CallTrace.log(String(format: "recorder: finished, %.1fs", duration))
        return Result(directory: directory, trackURLs: urls, duration: duration)
    }
}
