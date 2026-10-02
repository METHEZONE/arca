import Foundation
import AVFoundation
import ArcaVoiceCore

/// Turns a finished (or crash-truncated) CAF recording into a compact m4a.
///
/// Recordings are captured as PCM CAF because that is the only format that
/// survives the process dying mid-write (see `ChannelWriter`). An hour of it is
/// ~115 MB, so once the recording is over it is re-encoded to AAC (~15 MB/h).
///
/// The contract that keeps this from ever costing a recording:
/// - The CAF is never touched here. The caller deletes it only after the m4a is
///   recorded as the session's asset — until then the CAF stays the truth.
/// - The m4a is written under a temporary name and renamed into place only
///   after it has been re-opened and its length checked against the source,
///   so a kill mid-encode can never leave a half file posing as the real one.
public enum AudioFinalizer {
    public static let recordingExtension = "caf"

    /// Speech-grade AAC: plenty for playback and transcription.
    static var aacSettings: [String: Any] { [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 16_000,
        AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey: 32_000,
    ] }

    public enum FinalizeError: Error, LocalizedError {
        case unreadableSource(String)
        case lengthMismatch(source: TimeInterval, output: TimeInterval)

        public var errorDescription: String? {
            switch self {
            case .unreadableSource(let detail):
                return "The recording file couldn't be read: \(detail)"
            case .lengthMismatch(let source, let output):
                return String(format: "The compacted file is %.1fs but the recording is %.1fs — kept the original.",
                              output, source)
            }
        }
    }

    public static func isRecordingFile(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == recordingExtension
    }

    /// Where the compacted copy of `caf` lives: same directory, same channel name.
    public static func compactedURL(for caf: URL) -> URL {
        caf.deletingPathExtension().appendingPathExtension("m4a")
    }

    /// Whether every sample of `url` decodes. False for a file that won't open
    /// or throws partway through (killed mid-write before crash-safe capture)
    /// — damage no retry can fix. Decodes the whole file: call it only after
    /// a pass has already failed.
    public static func isFullyReadable(_ url: URL) -> Bool {
        guard let file = try? AVAudioFile(forReading: url), file.length > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 65_536)
        else { return false }
        do {
            while file.framePosition < file.length {
                try file.read(into: buffer)
                if buffer.frameLength == 0 { break }
            }
        } catch {
            return false
        }
        return true
    }

    /// Seconds of audio in a file, or 0 when it can't be opened.
    public static func duration(of url: URL) -> TimeInterval {
        guard let file = try? AVAudioFile(forReading: url),
              file.processingFormat.sampleRate > 0 else { return 0 }
        return Double(file.length) / file.processingFormat.sampleRate
    }

    /// Encodes `caf` to an m4a next to it and returns the m4a's URL. Throws —
    /// leaving any existing m4a and the CAF untouched — if the result can't be
    /// verified.
    public static func compact(_ caf: URL) throws -> URL {
        repairTruncatedTail(caf)
        let source: AVAudioFile
        do {
            source = try AVAudioFile(forReading: caf)
        } catch {
            throw FinalizeError.unreadableSource(error.localizedDescription)
        }
        let sourceSeconds = Double(source.length) / source.processingFormat.sampleRate

        let destination = compactedURL(for: caf)
        let partial = destination.appendingPathExtension("partial")
        try? FileManager.default.removeItem(at: partial)
        do {
            // Scoped so the writer is closed (moov written) before verification.
            let output = try AVAudioFile(forWriting: partial, settings: aacSettings,
                                         commonFormat: .pcmFormatFloat32, interleaved: false)
            let converter = BufferConverter()
            let chunkFrames: AVAudioFrameCount = 16_384
            guard let buffer = AVAudioPCMBuffer(pcmFormat: source.processingFormat,
                                                frameCapacity: chunkFrames) else {
                throw FinalizeError.unreadableSource("no buffer")
            }
            while source.framePosition < source.length {
                try source.read(into: buffer, frameCount: chunkFrames)
                guard buffer.frameLength > 0 else { break }
                try output.write(from: try converter.convert(buffer, to: output.processingFormat))
            }
            output.close()
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw error
        }

        // AAC adds a few priming frames and rounds to its packet size; anything
        // beyond half a second means frames went missing.
        let outputSeconds = duration(of: partial)
        guard abs(outputSeconds - sourceSeconds) <= 0.5 else {
            try? FileManager.default.removeItem(at: partial)
            throw FinalizeError.lengthMismatch(source: sourceSeconds, output: outputSeconds)
        }
        // Safe even if killed between the two calls: the CAF is still there.
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: partial, to: destination)
        return destination
    }

    /// A kill can land mid-`write`, leaving half a sample frame at the end of
    /// the data chunk. Readers tolerate it today, but trimming it costs nothing
    /// and keeps the file well-formed for any decoder. Only touches a CAF whose
    /// data chunk is still open-ended (size -1), i.e. one that was never closed.
    static func repairTruncatedTail(_ url: URL) {
        guard let handle = try? FileHandle(forUpdating: url) else { return }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 64 * 1024),
              header.count >= 8, header.prefix(4) == Data("caff".utf8) else { return }
        var offset = 8
        var bytesPerFrame = 0
        while offset + 12 <= header.count {
            let type = String(decoding: header[offset..<offset + 4], as: UTF8.self)
            let size = header[offset + 4..<offset + 12].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            let body = offset + 12
            if type == "desc", body + 32 <= header.count {
                // mBytesPerPacket, big-endian, after mSampleRate (8), mFormatID (4)
                // and mFormatFlags (4).
                bytesPerFrame = Int(header[body + 16..<body + 20].reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
            }
            if type == "data" {
                guard size == UInt64.max, bytesPerFrame > 0,
                      let fileSize = try? handle.seekToEnd() else { return }
                // The data chunk starts with a 4-byte edit count.
                let audioStart = UInt64(body + 4)
                guard fileSize > audioStart else { return }
                let excess = (fileSize - audioStart) % UInt64(bytesPerFrame)
                if excess > 0 { try? handle.truncate(atOffset: fileSize - excess) }
                return
            }
            guard size != UInt64.max else { return }
            offset = body + Int(size)
        }
    }
}
