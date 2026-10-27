import AVFoundation
import CoreAudio
import DictationCore
import os

/// Everything the Mac plays, as a 16 kHz mono stream: a global process tap
/// (macOS 14.2+) that leaves out ox-say's own audio. The tap needs the
/// "System Audio Recording" permission, which macOS asks for on first use
/// (NSAudioCaptureUsageDescription) and ties to a properly signed app.
///
/// Measured on macOS 26.5.1 (P0a, 2026-10-26): the default layout below — an aggregate device whose main
/// sub-device is the default output — recorded an OxPulse call in Brave cleanly, with no entitlement beyond
/// audio-input. The permission can show ON and still deliver only zeros until it is switched off and on; the
/// recorder's `SystemAudioGuard` catches that.
///
/// A restart builds the NEW tap and aggregate device first and tears the old pair down only once the new one is
/// running: CoreAudio allows several process taps and private aggregates at once (each is its own object, and the
/// IO procs share this class's serial queue), so a failed rebuild leaves the working tap in place instead of
/// recording nothing. For the instant both run, the same audio arrives twice; the channel writer drops the head of
/// a chunk that lies before what is written, so the overlap does not reach the file.
@available(macOS 14.2, *)
final class SystemAudioTap {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    /// One tap with its aggregate device, IO proc and converter. A converter per instance: the formats of an old and
    /// a new tap can differ, and one converter fed both would be reset on every buffer.
    private final class Instance {
        var tapID = AudioObjectID(kAudioObjectUnknown)
        var aggregateID = AudioObjectID(kAudioObjectUnknown)
        var procID: AudioDeviceIOProcID?
        let converter = PCM16kConverter()

        func teardown() {
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
    }

    /// Samples at 16 kHz and the host time (nanoseconds, `HostClock`) of the first one.
    var onSamples: (([Float], UInt64) -> Void)?

    private var current: Instance?
    private let queue = DispatchQueue(label: "io.github.anatolykoptev.ox-say.dictation.tap", qos: .userInitiated)
    private let log = Logger(subsystem: "io.github.anatolykoptev.ox-say.dictation", category: "meeting")
    private let counterLock = NSLock()
    private var retiredFailed = 0
    private var retiredEmpty = 0
    private var nilBuffers = 0
    private var exclusionMissing = 0

    /// Counters for the end-of-meeting line (#251): conversions that failed or came out empty, buffers that could not
    /// even be wrapped, and starts where ox-say's own process object could not be found for the exclusion.
    var counters: (failed: Int, empty: Int, nilBuffers: Int, exclusionMissing: Int) {
        let live = current?.converter
        return counterLock.withLock {
            (retiredFailed + (live?.failedConversions ?? 0), retiredEmpty + (live?.emptyConversions ?? 0), nilBuffers, exclusionMissing)
        }
    }

    /// `withMainSubDevice`: bind the aggregate device to the current default
    /// output device, the layout the AudioCap reference app uses and P0a measured as working.
    func start(excludingPIDs pids: [pid_t], withMainSubDevice: Bool) throws {
        var excluded: [AudioObjectID] = []
        for pid in pids {
            // The process object of this very app appears once it uses audio; give it a moment before giving up.
            let object = Retry.firstNonNil(attempts: 4, wait: { Thread.sleep(forTimeInterval: 0.05) }) { Self.processObject(for: pid) }
            if let object {
                excluded.append(object)
            } else {
                counterLock.withLock { exclusionMissing += 1 }
                log.error("system audio tap: no audio process object for pid \(pid, privacy: .public); this app's own sound is not excluded")
            }
        }
        let fresh = try build(excluded: excluded, withMainSubDevice: withMainSubDevice)
        let old = current
        current = fresh
        if let old {
            counterLock.withLock {
                retiredFailed += old.converter.failedConversions
                retiredEmpty += old.converter.emptyConversions
            }
            old.teardown()
        }
    }

    private func build(excluded: [AudioObjectID], withMainSubDevice: Bool) throws -> Instance {
        let instance = Instance()
        func fail(_ message: String) -> Failure {
            instance.teardown()
            return Failure(description: message)
        }
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
        description.uuid = UUID()
        description.muteBehavior = .unmuted
        description.isPrivate = true
        var tap = AudioObjectID(kAudioObjectUnknown)
        var err = AudioHardwareCreateProcessTap(description, &tap)
        guard err == noErr else { throw Failure(description: "The system audio tap could not start (\(err)).") }
        instance.tapID = tap

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
        guard err == noErr else { throw fail("The system audio device could not be created (\(err)).") }
        instance.aggregateID = device

        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        err = AudioObjectGetPropertyData(instance.tapID, &address, 0, nil, &size, &format)
        guard err == noErr, let avFormat = AVAudioFormat(streamDescription: &format) else {
            throw fail("The system audio format is unreadable (\(err)).")
        }

        err = AudioDeviceCreateIOProcIDWithBlock(&instance.procID, instance.aggregateID, queue) { [weak self, weak instance] _, input, time, _, _ in
            guard let self, let instance else { return }
            // A buffer that cannot be wrapped is counted, not skipped silently.
            guard let buffer = AVAudioPCMBuffer(pcmFormat: avFormat, bufferListNoCopy: input, deallocator: nil) else {
                self.counterLock.withLock { self.nilBuffers += 1 }
                return
            }
            guard let samples = instance.converter.convert(buffer) else { return }
            // The CAPTURE time of the buffer's first sample, from the one clock every channel is stamped by (#247);
            // a timestamp without a valid host time is replaced by now, as the microphone path does.
            let ticks = time.pointee.mFlags.contains(.hostTimeValid) ? time.pointee.mHostTime : AudioGetCurrentHostTime()
            self.onSamples?(samples, HostClock.nanos(fromHostTicks: ticks))
        }
        guard err == noErr, instance.procID != nil else { throw fail("The system audio reader could not start (\(err)).") }
        err = AudioDeviceStart(instance.aggregateID, instance.procID)
        guard err == noErr else { throw fail("The system audio reader could not start (\(err)).") }
        return instance
    }

    func stop() {
        current?.teardown()
        if let old = current {
            counterLock.withLock {
                retiredFailed += old.converter.failedConversions
                retiredEmpty += old.converter.emptyConversions
            }
        }
        current = nil
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
