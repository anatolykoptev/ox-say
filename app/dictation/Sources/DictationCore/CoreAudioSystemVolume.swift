import AudioToolbox
import Foundation

/// The default output's software volume behind "Lower All Sound", through
/// CoreAudio's AudioObject API — no Apple Events, so no permission prompt on
/// this path. `kAudioHardwareServiceDeviceProperty_VirtualMainVolume` is what
/// the volume keys move; on a device whose hardware has no volume of its own
/// it is applied digitally, so it works anywhere the volume HUD does. Every
/// call is synchronous and brief: they run on the runner's serial queue, off
/// the main thread.
public final class CoreAudioSystemVolume: SystemVolume {
    public init() {}

    private static func address(_ selector: AudioObjectPropertySelector,
                                _ scope: AudioObjectPropertyScope) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    public func defaultDevice() -> (id: UInt32, uid: String?)? {
        var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice,
                                   kAudioObjectPropertyScopeGlobal)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                         0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return nil }
        return (id: device, uid: uid(of: device))
    }

    /// The device's persistent UID — survives re-enumeration, which an
    /// AudioObjectID does not.
    private func uid(of device: AudioDeviceID) -> String? {
        var address = Self.address(kAudioDevicePropertyDeviceUID,
                                   kAudioObjectPropertyScopeGlobal)
        var ref: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &ref) == noErr,
              let ref else { return nil }
        return ref.takeRetainedValue() as String
    }

    /// The AudioObjectID a UID resolves to now; the translate property answers
    /// `kAudioObjectUnknown` (read here as nil) for a device that went away.
    public func device(forUID uid: String) -> UInt32? {
        var address = Self.address(kAudioHardwarePropertyTranslateUIDToDevice,
                                   kAudioObjectPropertyScopeGlobal)
        var input = uid as CFString
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        // The UID goes in as the property's qualifier, not a translation.
        let status = withUnsafePointer(to: &input) { pointer in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                       UInt32(MemoryLayout<CFString>.size), UnsafeRawPointer(pointer),
                                       &size, &device)
        }
        guard status == noErr, device != kAudioObjectUnknown else { return nil }
        return device
    }

    public func isSettable(_ device: UInt32) -> Bool {
        var address = Self.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                   kAudioObjectPropertyScopeOutput)
        var settable = DarwinBoolean(false)
        return AudioObjectIsPropertySettable(device, &address, &settable) == noErr
            && settable.boolValue
    }

    public func volume(_ device: UInt32) -> Float? {
        var address = Self.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                   kAudioObjectPropertyScopeOutput)
        var level = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &level) == noErr
        else { return nil }
        return level
    }

    public func isMuted(_ device: UInt32) -> Bool {
        var address = Self.address(kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput)
        var muted = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &muted) == noErr
            && muted != 0
    }

    @discardableResult
    public func setVolume(_ device: UInt32, _ level: Float) -> Bool {
        var address = Self.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                   kAudioObjectPropertyScopeOutput)
        var level = level
        return AudioObjectSetPropertyData(device, &address, 0, nil,
                                          UInt32(MemoryLayout<Float32>.size), &level) == noErr
    }
}
