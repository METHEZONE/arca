#if os(macOS)
import Foundation
import AudioToolbox
import AVFoundation
import ArcaVoiceCore

/// Global system-audio capture via Core Audio process taps (macOS 14.4+).
///
/// Known traps this implementation respects (validated against AudioCap/audiotee):
/// - Do NOT touch `isExclusive` — it's a scope selector, not a lock; mutating it
///   silently yields zero samples.
/// - AVAudioEngine cannot retarget to a tap-backed aggregate (returns noErr while
///   reading the default input) — the IOProc is registered directly via
///   `AudioDeviceCreateIOProcIDWithBlock` with a non-nil queue.
/// - The aggregate needs a real output device as main sub-device, the tap in the
///   tap list with drift compensation, and TapAutoStart.
/// - Teardown order is strict: stop device → destroy IOProc → destroy aggregate
///   → destroy tap.
/// - The binary must be signed or the TCC prompt (NSAudioCaptureUsageDescription)
///   never fires.
final class SystemAudioTap: @unchecked Sendable {
    private var tapID: AudioObjectID = kAudioObjectUnknown
    private var aggregateID: AudioObjectID = kAudioObjectUnknown
    private var ioProcID: AudioDeviceIOProcID?
    private let ioQueue = DispatchQueue(label: "com.thezone.arca.voice.systemtap", qos: .userInitiated)
    private(set) var streamDescription: AudioStreamBasicDescription?
    private var running = false

    /// Creates the tap and aggregate device. Triggers the system-audio TCC
    /// prompt on first run.
    func activate() throws {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.name = "ARCA System Tap"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var newTapID = AudioObjectID(kAudioObjectUnknown)
        var err = AudioHardwareCreateProcessTap(description, &newTapID)
        guard err == noErr, newTapID.isValidObject else {
            throw CaptureError.tapCreationFailed(err)
        }
        tapID = newTapID
        streamDescription = try tapID.readTapStreamDescription()

        let outputID = try AudioObjectID.readDefaultSystemOutputDevice()
        let outputUID = try outputID.readDeviceUID()

        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "ARCA Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                ]
            ],
        ]

        var newAggregateID = AudioObjectID(kAudioObjectUnknown)
        err = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &newAggregateID)
        guard err == noErr, newAggregateID.isValidObject else {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
            throw CaptureError.aggregateDeviceCreationFailed(err)
        }
        aggregateID = newAggregateID
    }

    /// Starts IO. `onBuffer` is called on the internal IO queue.
    func start(onBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws {
        guard aggregateID.isValidObject, var asbd = streamDescription else {
            throw CaptureError.formatUnavailable
        }
        guard let format = AVAudioFormat(streamDescription: &asbd) else {
            throw CaptureError.formatUnavailable
        }

        var err = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, ioQueue) { _, inInputData, _, _, _ in
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: inInputData, deallocator: nil) else {
                return
            }
            onBuffer(buffer)
        }
        guard err == noErr else { throw CaptureError.ioProcFailed(err) }

        err = AudioDeviceStart(aggregateID, ioProcID)
        guard err == noErr else { throw CaptureError.deviceStartFailed(err) }
        running = true
    }

    func stop() {
        if running, let ioProcID {
            AudioDeviceStop(aggregateID, ioProcID)
        }
        if let ioProcID, aggregateID.isValidObject {
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            self.ioProcID = nil
        }
        if aggregateID.isValidObject {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = kAudioObjectUnknown
        }
        if tapID.isValidObject {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
        running = false
    }

    deinit { stop() }
}
#endif
