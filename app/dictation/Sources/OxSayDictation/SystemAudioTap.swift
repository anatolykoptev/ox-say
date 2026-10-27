import AVFoundation
import CoreAudio
import DictationCore

/// Everything the Mac plays, as a 16 kHz mono stream: a global process tap
/// (macOS 14.2+) that leaves out ox-say's own audio. The tap needs the
/// "System Audio Recording" permission, which macOS asks for on first use
/// (NSAudioCaptureUsageDescription) and ties to a properly signed app.
///
/// Measured on macOS 26.5.1 (P0a, 2026-10-26): the default layout below — an aggregate device whose main
/// sub-device is the default output — recorded an OxPulse call in Brave cleanly, with no entitlement beyond
/// audio-input. The permission can show ON and still deliver only zeros until it is switched off and on; the
/// recorder's `SystemAudioGuard` catches that.
@available(macOS 14.2, *)
final class SystemAudioTap {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    /// Samples at 16 kHz and the host time (nanoseconds, `HostClock`) of the first one.
    var onSamples: (([Float], UInt64) -> Void)?

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "io.github.anatolykoptev.ox-say.dictation.tap", qos: .userInitiated)
    private let converter = PCM16kConverter()

    /// Buffers the converter could not turn into 16 kHz samples, and ones that came out empty (#251): logged at the end.
    var conversionCounters: (failed: Int, empty: Int) { (converter.failedConversions, converter.emptyConversions) }

    /// `withMainSubDevice`: bind the aggregate device to the current default
    /// output device, the layout the AudioCap reference app uses and P0a measured as working.
    func start(excludingPIDs pids: [pid_t], withMainSubDevice: Bool) throws {
        stop()
        let excluded = pids.compactMap(Self.processObject(for:))
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
        description.uuid = UUID()
        description.muteBehavior = .unmuted
        description.isPrivate = true
        var tap = AudioObjectID(kAudioObjectUnknown)
        var err = AudioHardwareCreateProcessTap(description, &tap)
        guard err == noErr else { throw Failure(description: "The system audio tap could not start (\(err)).") }
        tapID = tap

        var aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "ox-say meeting tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        if withMainSubDevice, let uid = CoreAudioProps.defaultOutputUID() {
            aggregate[kAudioAggregateDeviceMainSubDeviceKey] = uid
            aggregate[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: uid]]
        }
        var device = AudioObjectID(kAudioObjectUnknown)
        err = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device)
        guard err == noErr else {
            stop()
            throw Failure(description: "The system audio device could not be created (\(err)).")
        }
        aggregateID = device

        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        err = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format)
        guard err == noErr, let avFormat = AVAudioFormat(streamDescription: &format) else {
            stop()
            throw Failure(description: "The system audio format is unreadable (\(err)).")
        }

        err = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { [weak self] _, input, time, _, _ in
            guard let self,
                  let buffer = AVAudioPCMBuffer(pcmFormat: avFormat, bufferListNoCopy: input, deallocator: nil),
                  let samples = self.converter.convert(buffer) else { return }
            // The CAPTURE time of the buffer's first sample, from the one clock every channel is stamped by (#247).
            self.onSamples?(samples, HostClock.nanos(fromHostTicks: time.pointee.mHostTime))
        }
        guard err == noErr, procID != nil else {
            stop()
            throw Failure(description: "The system audio reader could not start (\(err)).")
        }
        err = AudioDeviceStart(aggregateID, procID)
        guard err == noErr else {
            stop()
            throw Failure(description: "The system audio reader could not start (\(err)).")
        }
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    private static func processObject(for pid: pid_t) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var qualifier = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let err = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                             UInt32(MemoryLayout<pid_t>.size), &qualifier, &size, &object)
        return err == noErr && object != kAudioObjectUnknown ? object : nil
    }
}
