#if os(macOS)
import Foundation
import AudioToolbox

/// Snapshot of which processes are currently capturing the microphone —
/// the signal ARCA Voice uses to detect a meeting starting.
public enum MicActivity {
    public struct MicUser: Equatable, Sendable {
        public let pid: pid_t
        public let bundleID: String?
    }

    /// Processes with a live microphone input stream, excluding ourselves.
    public static func currentMicUsers() -> [MicUser] {
        guard let processObjects = try? readProcessObjectList() else { return [] }
        var users: [MicUser] = []
        let ownPID = ProcessInfo.processInfo.processIdentifier
        for object in processObjects {
            guard readBool(object, selector: kAudioProcessPropertyIsRunningInput) == true else { continue }
            guard let pid = readPID(object), pid != pid_t(ownPID) else { continue }
            users.append(MicUser(pid: pid, bundleID: readString(object, selector: kAudioProcessPropertyBundleID)))
        }
        return users
    }

    // MARK: - Core Audio property plumbing

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static func readProcessObjectList() throws -> [AudioObjectID] {
        var addr = address(kAudioHardwarePropertyProcessObjectList)
        var dataSize: UInt32 = 0
        var err = AudioObjectGetPropertyDataSize(AudioObjectID.systemObject, &addr, 0, nil, &dataSize)
        guard err == noErr else { throw CaptureError.ioProcFailed(err) }
        var list = [AudioObjectID](repeating: kAudioObjectUnknown,
                                   count: Int(dataSize) / MemoryLayout<AudioObjectID>.size)
        err = AudioObjectGetPropertyData(AudioObjectID.systemObject, &addr, 0, nil, &dataSize, &list)
        guard err == noErr else { throw CaptureError.ioProcFailed(err) }
        return list
    }

    private static func readBool(_ object: AudioObjectID, selector: AudioObjectPropertySelector) -> Bool? {
        var addr = address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value == 1
    }

    private static func readPID(_ object: AudioObjectID) -> pid_t? {
        var addr = address(kAudioProcessPropertyPID)
        var value: pid_t = -1
        var size = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr, value > 0 else { return nil }
        return value
    }

    private static func readString(_ object: AudioObjectID, selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.stride)
        let err = withUnsafeMutablePointer(to: &value) { ptr in
            AudioObjectGetPropertyData(object, &addr, 0, nil, &size, ptr)
        }
        guard err == noErr else { return nil }
        let string = value as String
        return string.isEmpty ? nil : string
    }
}
#endif
