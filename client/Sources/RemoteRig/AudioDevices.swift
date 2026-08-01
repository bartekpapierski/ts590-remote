import CoreAudio

// Device enumeration / selection backed by the CoreAudio C API so it
// works on every macOS SDK (AVAudioHardware is not present in the
// Command Line Tools SDK).
enum AudioDevices {
    struct Device: Identifiable {
        let id: AudioDeviceID
        let name: String
        var identifier: AudioDeviceID { id }
    }

    static var inputDevices: [Device] {
        all().compactMap { d in
            isInput(d.id) ? d : nil
        }
    }

    static var outputDevices: [Device] {
        all().compactMap { d in
            isOutput(d.id) ? d : nil
        }
    }

    static func setDefaultInput(_ id: AudioDeviceID) { setDefault(kAudioHardwarePropertyDefaultInputDevice, id) }
    static func setDefaultOutput(_ id: AudioDeviceID) { setDefault(kAudioHardwarePropertyDefaultOutputDevice, id) }

    // MARK: CoreAudio
    private static func all() -> [Device] {
        guard let ids = deviceIDs() else { return [] }
        return ids.compactMap { id in
            guard let n = name(of: id) else { return nil }
            return Device(id: id, name: n)
        }
    }

    private static func deviceIDs() -> [AudioDeviceID]? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return nil }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.stride
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return nil }
        return Array(ids)
    }

    private static func name(of id: AudioDeviceID) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>>.stride)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &name) == noErr,
              let cf = name?.takeUnretainedValue() else { return nil }
        return cf as String
    }

    private static func hasStreams(_ id: AudioDeviceID, _ scope: AudioObjectPropertyScope) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr && size > 0
    }

    private static func isInput(_ id: AudioDeviceID) -> Bool {
        hasStreams(id, kAudioDevicePropertyScopeInput)
    }

    private static func isOutput(_ id: AudioDeviceID) -> Bool {
        hasStreams(id, kAudioDevicePropertyScopeOutput)
    }

    private static func setDefault(_ selector: AudioObjectPropertySelector, _ id: AudioDeviceID) {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var copy = id
        _ = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil,
            UInt32(MemoryLayout<AudioDeviceID>.stride), &copy)
    }
}
