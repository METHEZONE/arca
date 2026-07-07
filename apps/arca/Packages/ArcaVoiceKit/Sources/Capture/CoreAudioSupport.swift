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
