import Foundation
import AVFoundation
import ArcaVoiceCore

/// Microphone capture via AVAudioEngine — works on macOS and iOS.
final class MicCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var writer: ChannelWriter?
    #if os(macOS)
    private var previousDefaultInput: AudioDeviceID?
    #endif

    static func requestPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    func start(directory: URL, onBuffer: @escaping (CapturedBuffer) -> Void) throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default,
                                options: [.defaultToSpeaker, .allowBluetoothHFP])
        try session.setActive(true)
        #endif

        let input = engine.inputNode
        #if os(macOS)
        // A Bluetooth speaker as default input drags the whole system into
        // 16kHz HFP call mode the moment we record (music turns to walkie-
        // talkie) and its far-away mic records garbage. Pin the engine's
        // input unit to the built-in mic (system default switch alone gets
        // reverted by macOS's BT preference), then reset so the node's
        // format reflects the real device.
        if let builtin = Self.builtInInputDevice(),
           Self.defaultInputTransport() == kAudioDeviceTransportTypeBluetooth {
            previousDefaultInput = Self.currentDefaultInput()
            if !Self.setDefaultInput(builtin) { previousDefaultInput = nil }
            var deviceID = builtin
            if let unit = input.audioUnit {
                let err = AudioUnitSetProperty(
                    unit, kAudioOutputUnitProperty_CurrentDevice,
                    kAudioUnitScope_Global, 0,
                    &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size))
                CaptureTrace.log("mic: pin input unit to built-in → \(err == noErr ? "ok" : "err \(err)")")
            }
            engine.reset()
            Thread.sleep(forTimeInterval: 0.25) // let CoreAudio settle the switch
        }
        #endif
        let format = input.outputFormat(forBus: 0)
        CaptureTrace.log("mic: input format \(format.sampleRate)Hz x\(format.channelCount)")
        guard format.sampleRate > 0 else {
            restoreDefaultInputIfNeeded()
            throw CaptureError.formatUnavailable
        }

        let writer = try ChannelWriter(channel: .microphone, directory: directory, sourceFormat: format)
        self.writer = writer

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            if let captured = writer.write(buffer) {
                onBuffer(captured)
            }
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            restoreDefaultInputIfNeeded()
            throw error
        }
    }

    private func restoreDefaultInputIfNeeded() {
        #if os(macOS)
        if let previous = previousDefaultInput {
            _ = Self.setDefaultInput(previous)
            previousDefaultInput = nil
            CaptureTrace.log("mic: default input restored")
        }
        #endif
    }

    #if os(macOS)
    private static func currentDefaultInput() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &size, &deviceID) == noErr,
              deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    private static func setDefaultInput(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var device = deviceID
        return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                          &address, 0, nil,
                                          UInt32(MemoryLayout<AudioDeviceID>.size), &device) == noErr
    }

    private static func defaultInputTransport() -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &size, &deviceID) == noErr else { return 0 }
        var transport = UInt32(0)
        var transportAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(deviceID, &transportAddress, 0, nil, &size, &transport)
        return transport
    }

    private static func builtInInputDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                             &address, 0, nil, &size) == noErr else { return nil }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var devices = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &size, &devices) == noErr else { return nil }
        for device in devices {
            var transport = UInt32(0)
            var transportAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyTransportType,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            var transportSize = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(device, &transportAddress, 0, nil,
                                             &transportSize, &transport) == noErr,
                  transport == kAudioDeviceTransportTypeBuiltIn else { continue }
            // Must actually have input channels.
            var streamsAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioObjectPropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain)
            var streamsSize = UInt32(0)
            guard AudioObjectGetPropertyDataSize(device, &streamsAddress, 0, nil,
                                                 &streamsSize) == noErr, streamsSize > 0 else { continue }
            return device
        }
        return nil
    }
    #endif

    func stop() -> (url: URL, duration: TimeInterval)? {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        restoreDefaultInputIfNeeded()
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
        guard let writer else { return nil }
        return (writer.fileURL, writer.elapsed)
    }
}
