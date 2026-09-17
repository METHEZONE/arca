#if os(macOS)
import Foundation
import AudioToolbox

extension AudioObjectID {
    static let systemObject = AudioObjectID(kAudioObjectSystemObject)

    var isValidObject: Bool { self != kAudioObjectUnknown }

    static func readDefaultSystemOutputDevice() throws -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let err = AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, &deviceID)
        guard err == noErr, deviceID.isValidObject else {
            throw CaptureError.aggregateDeviceCreationFailed(err)
        }
        return deviceID
    }

    static func readDefaultOutputDevice() throws -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let err = AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, &deviceID)
        guard err == noErr, deviceID.isValidObject else {
            throw CaptureError.aggregateDeviceCreationFailed(err)
        }
        return deviceID
    }

    /// The real output device to anchor the tap aggregate on.
    ///
    /// The tap aggregate needs a physical output device as its main
    /// sub-device for a clock. Anchoring on the *system* output device broke
    /// the moment the user's system output was itself an aggregate ("다중 출력
    /// 기기" for a DJ setup): an aggregate inside an aggregate runs the IOProc
    /// with all-zero buffers, and a whole video call recorded as silence.
    /// So: the default output device apps actually play to; if that is an
    /// aggregate, its first real sub-device; failing both, the built-in
    /// speakers.
    static func readTapAnchorOutputDevice() throws -> AudioDeviceID {
        let preferred = (try? readDefaultOutputDevice()) ?? (try? readDefaultSystemOutputDevice())
        if let preferred {
            if preferred.readTransportType() != kAudioDeviceTransportTypeAggregate {
                return preferred
            }
            if let sub = preferred.readActiveSubDevices().first(where: {
                $0.readTransportType() != kAudioDeviceTransportTypeAggregate && $0.hasStreams(scope: kAudioObjectPropertyScopeOutput)
            }) {
                CaptureTrace.log("tap: default output '\(preferred.readName())' is an aggregate — anchoring on sub-device '\(sub.readName())'")
                return sub
            }
        }
        if let builtin = allDevices().first(where: {
            $0.readTransportType() == kAudioDeviceTransportTypeBuiltIn && $0.hasStreams(scope: kAudioObjectPropertyScopeOutput)
        }) {
            CaptureTrace.log("tap: no usable default output — anchoring on built-in '\(builtin.readName())'")
            return builtin
        }
        guard let preferred else { throw CaptureError.aggregateDeviceCreationFailed(kAudioHardwareBadDeviceError) }
        return preferred
    }

    static func allDevices() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(systemObject, &address, 0, nil, &size) == noErr else { return [] }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, &devices) == noErr else { return [] }
        return devices
    }

    func readTransportType() -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var transport = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(self, &address, 0, nil, &size, &transport)
        return transport
    }

    func readActiveSubDevices() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioAggregateDevicePropertyActiveSubDeviceList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(self, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(self, &address, 0, nil, &size, &devices) == noErr else { return [] }
        return devices
    }

    func hasStreams(scope: AudioObjectPropertyScope) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(0)
        return AudioObjectGetPropertyDataSize(self, &address, 0, nil, &size) == noErr && size > 0
    }

    func readName() -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var name: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.stride)
        let err = withUnsafeMutablePointer(to: &name) { ptr in
            AudioObjectGetPropertyData(self, &address, 0, nil, &size, ptr)
        }
        return err == noErr ? (name as String) : "device \(self)"
    }

    func readDeviceUID() throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.stride)
        let err = withUnsafeMutablePointer(to: &uid) { ptr in
            AudioObjectGetPropertyData(self, &address, 0, nil, &size, ptr)
        }
        guard err == noErr else { throw CaptureError.aggregateDeviceCreationFailed(err) }
        return uid as String
    }

    func readTapStreamDescription() throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var description = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.stride)
        let err = AudioObjectGetPropertyData(self, &address, 0, nil, &size, &description)
        guard err == noErr else { throw CaptureError.tapCreationFailed(err) }
        return description
    }
}
#endif
