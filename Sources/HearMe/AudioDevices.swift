import AudioToolbox
import CoreAudio
import Foundation

/// Microphones known to Core Audio.
struct AudioInputDevice: Equatable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let isBuiltIn: Bool
    let isBluetooth: Bool
}

enum AudioDevices {
    /// Saved choice: "system" (default), "builtin", or a device UID.
    static let builtInChoice = "builtin"
    static let systemChoice = "system"

    static func inputs() -> [AudioInputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }

        return ids.compactMap { id in
            guard hasInput(id) else { return nil }
            let transport = uint32(id, kAudioDevicePropertyTransportType)
            return AudioInputDevice(
                id: id,
                uid: string(id, kAudioDevicePropertyDeviceUID) ?? "",
                name: string(id, kAudioObjectPropertyName) ?? "Microphone",
                isBuiltIn: transport == kAudioDeviceTransportTypeBuiltIn,
                isBluetooth: transport == kAudioDeviceTransportTypeBluetooth
                    || transport == kAudioDeviceTransportTypeBluetoothLE)
        }
    }

    /// The device for a saved choice, or nil to use the system default input.
    static func resolve(_ choice: String) -> AudioInputDevice? {
        let all = inputs()
        switch choice {
        case systemChoice: return nil
        case builtInChoice: return all.first { $0.isBuiltIn }
        default: return all.first { $0.uid == choice } ?? all.first { $0.isBuiltIn }
        }
    }

    private static func hasInput(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func uint32(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value)
        return value
    }

    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr,
              let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
