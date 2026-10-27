import CoreAudio

/// Small typed reads of CoreAudio object properties.
enum CoreAudioProps {
    static func defaultOutputDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let err = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return err == noErr && device != kAudioObjectUnknown ? device : nil
    }

    static func defaultOutputUID() -> String? {
        guard let device = defaultOutputDevice() else { return nil }
        return string(device, kAudioDevicePropertyDeviceUID)
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                       scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    static func uint32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                       scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    /// The output device's route, for the echo decision.
    static func outputRoute() -> (transport: String, dataSource: String?, name: String)? {
        guard let device = defaultOutputDevice() else { return nil }
        func code(_ v: UInt32) -> String {
            String(bytes: [UInt8(v >> 24 & 255), UInt8(v >> 16 & 255), UInt8(v >> 8 & 255), UInt8(v & 255)], encoding: .macOSRoman) ?? ""
        }
        let transport = uint32(device, kAudioDevicePropertyTransportType).map(code) ?? ""
        let source = uint32(device, kAudioDevicePropertyDataSource, scope: kAudioObjectPropertyScopeOutput).map(code)
        return (transport, source, string(device, kAudioObjectPropertyName) ?? "")
    }
}

extension CoreAudioProps {
    /// The processes CoreAudio knows (macOS 14.2+): pid, bundle id and whether each has input / output running.
    /// nil when CoreAudio itself failed — not the same as "no process has audio" (`[]`).
    @available(macOS 14.2, *)
    static func audioProcesses() -> [(pid: Int32, bundleID: String, runningInput: Bool, runningOutput: Bool)]? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return nil }
        guard size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &objects) == noErr else { return nil }
        return objects.compactMap { object in
            guard let pid = uint32(object, kAudioProcessPropertyPID), let running = uint32(object, kAudioProcessPropertyIsRunningInput),
                  let bundle = string(object, kAudioProcessPropertyBundleID) else { return nil }
            let playing = uint32(object, kAudioProcessPropertyIsRunningOutput) ?? 0
            return (Int32(bitPattern: pid), bundle, running != 0, playing != 0)
        }
    }
}
