import AVFoundation
import CoreAudio
import DictationCore

/// Records a meeting as two files in the meeting's directory: me.pcm (the
/// microphone) and them.pcm (everything the Mac plays), raw 16 kHz mono, both
/// starting at the same instant. Samples are appended as they arrive, so the
/// app dying costs the last fraction of a second.
///
/// Clock contract (#247): one t0 for both channels, and every chunk is stamped with the CAPTURE time of its first
/// sample — `HostClock.nanos(fromHostTicks:)` of the buffer's host time — never with the time it was delivered, so a
/// burst after a stall is placed where it was recorded instead of being padded and then trimmed.
@available(macOS 14.2, *)
final class MeetingRecorder {
    enum StartError: Error, CustomStringConvertible {
        case microphone(String)
        var description: String {
            switch self {
            case .microphone(let why): return why
            }
        }
    }

    /// What a finished recording did with the clock: logged by the controller as numbers, never as content.
    struct Summary {
        var meDropped = 0, mePadded = 0, themDropped = 0, themPadded = 0
        var micConversions: (failed: Int, empty: Int) = (0, 0)
        var tapConversions: (failed: Int, empty: Int) = (0, 0)
        var failedWrites = 0
    }

    /// The other side counts as active while its last loud chunk is this recent.
    private static let activeWindow: TimeInterval = 3
    private static let loudRMS: Float = 0.003

    /// Called on the main thread when the system audio could not be (re)started.
    var onSystemAudioFailed: ((String) -> Void)?
    /// Called on the main thread when the microphone could not be restarted after a route change.
    var onMicrophoneFailed: ((String) -> Void)?

    private let mic = AVAudioEngine()
    private let micConverter = PCM16kConverter()
    private let tap = SystemAudioTap()
    private var me: PcmChannelWriter?
    private var them: PcmChannelWriter?
    private var outputListener: AudioObjectPropertyListenerBlock?
    private var rebuildWork: DispatchWorkItem?
    private let lock = NSLock()
    private var meLevel: Float = 0
    private var themLevel: Float = 0
    private var themLoudAt = Date.distantPast
    private var themEverLoud = false
    private var tapCallbacks = 0
    private var tapPeak: Float = 0
    private var micObserver: NSObjectProtocol?
    private(set) var started: Date?
    /// P0a (macOS 26.5.1): the default layout, main sub-device = the default output, recorded cleanly. Branch A.
    var useMainSubDevice = true

    var levels: (me: Float, them: Float) { lock.withLock { (meLevel, themLevel) } }
    var themActive: Bool { lock.withLock { Date().timeIntervalSince(themLoudAt) < Self.activeWindow } }
    /// The other side was audible at least once since the recording began: false
    /// after a while means the system audio permission is off or the tap is silent.
    var heardTheOtherSide: Bool { lock.withLock { themEverLoud } }
    /// What the tap has delivered: buffers that gave samples, and the largest absolute sample so far.
    var tapStats: (callbacks: Int, peak: Float) { lock.withLock { (tapCallbacks, tapPeak) } }
    /// A channel file could not be written (a full disk): the recording is incomplete.
    var writeFailed: Bool { (me?.failedWrites ?? 0) > 0 || (them?.failedWrites ?? 0) > 0 }
    var elapsed: TimeInterval { started.map { Date().timeIntervalSince($0) } ?? 0 }

    /// Microphone permission, asked for BEFORE a meeting is opened in the daemon: a permission still undetermined is
    /// requested, not reported as off, and nothing is created that would then have to be thrown away.
    static func checkMicrophone() throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
            throw StartError.microphone(L10nKey.meetingMicAllow.text)
        default:
            throw StartError.microphone(L10nKey.meetingMicOff.text)
        }
    }

    func start(into dir: URL) throws {
        try Self.checkMicrophone()
        let t0 = HostClock.nanos(fromHostTicks: AudioGetCurrentHostTime())
        me = try PcmChannelWriter(url: dir.appendingPathComponent("me.pcm"), t0: t0)
        do {
            them = try PcmChannelWriter(url: dir.appendingPathComponent("them.pcm"), t0: t0)
        } catch {
            me?.finish(atNanos: t0)
            me = nil
            throw error
        }
        lock.withLock {
            meLevel = 0; themLevel = 0; themLoudAt = .distantPast; themEverLoud = false; tapCallbacks = 0; tapPeak = 0
        }

        do {
            try startMicrophone()
        } catch {
            // Neither writer may stay open on a recording that never began.
            me?.finish(atNanos: t0)
            them?.finish(atNanos: t0)
            me = nil
            them = nil
            throw error
        }
        // AirPods connecting or a new default input stops the engine; without this
        // the microphone channel would go silent for the rest of the call.
        micObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: mic, queue: .main) { [weak self] _ in
            guard let self, self.started != nil else { return }
            self.mic.inputNode.removeTap(onBus: 0)
            self.mic.stop()
            do { try self.startMicrophone() } catch { self.onMicrophoneFailed?("\(error)") }
        }

        tap.onSamples = { [weak self] samples, nanos in
            guard let self else { return }
            self.them?.append(samples, atNanos: nanos)
            let level = Self.rms(samples)
            let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
            self.lock.withLock {
                self.themLevel = level
                self.tapCallbacks += 1
                self.tapPeak = max(self.tapPeak, peak)
                if level > Self.loudRMS {
                    self.themLoudAt = Date()
                    self.themEverLoud = true
                }
            }
        }
        do {
            try tap.start(excludingPIDs: [getpid()], withMainSubDevice: useMainSubDevice)
        } catch {
            // The microphone alone is still a recording; say what is missing.
            DispatchQueue.main.async { [weak self] in self?.onSystemAudioFailed?("\(error)") }
        }
        started = Date()
        watchOutputDevice()
    }

    private func startMicrophone() throws {
        let input = mic.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw StartError.microphone(L10nKey.meetingMicNone.text) }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, when in
            guard let self, let samples = self.micConverter.convert(buffer) else { return }
            let ticks = when.isHostTimeValid ? when.hostTime : AudioGetCurrentHostTime()
            self.me?.append(samples, atNanos: HostClock.nanos(fromHostTicks: ticks))
            self.lock.withLock { self.meLevel = Self.rms(samples) }
        }
        mic.prepare()
        try mic.start()
    }

    /// Stops both sources, pads both files to the same length and closes them. The numbers go back to the caller.
    @discardableResult
    func stop() -> Summary {
        if let micObserver { NotificationCenter.default.removeObserver(micObserver) }
        micObserver = nil
        unwatchOutputDevice()
        mic.inputNode.removeTap(onBus: 0)
        mic.stop()
        tap.stop()
        let end = HostClock.nanos(fromHostTicks: AudioGetCurrentHostTime())
        me?.finish(atNanos: end)
        them?.finish(atNanos: end)
        var summary = Summary()
        summary.meDropped = me?.droppedSamples ?? 0
        summary.mePadded = me?.paddedSamples ?? 0
        summary.themDropped = them?.droppedSamples ?? 0
        summary.themPadded = them?.paddedSamples ?? 0
        summary.failedWrites = (me?.failedWrites ?? 0) + (them?.failedWrites ?? 0)
        summary.micConversions = (micConverter.failedConversions, micConverter.emptyConversions)
        summary.tapConversions = tap.conversionCounters
        me = nil
        them = nil
        started = nil
        return summary
    }

    /// Whether the call is heard through speakers (decided once, when the meeting starts).
    static func echoRisk() -> Bool {
        guard let route = CoreAudioProps.outputRoute() else { return true }
        return OutputRoute.isLikelySpeakers(transport: route.transport, dataSource: route.dataSource, name: route.name)
    }

    // The tap is bound to the output device it started on; AirPods connecting
    // mid-call would leave it silent, so a change rebuilds it. The gap is
    // padded with silence by the channel writer.
    private func watchOutputDevice() {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async { self?.scheduleTapRebuild() }
        }
        outputListener = block
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block)
    }

    private func unwatchOutputDevice() {
        rebuildWork?.cancel()
        guard let block = outputListener else { return }
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block)
        outputListener = nil
    }

    private func scheduleTapRebuild() {
        rebuildWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.started != nil else { return }
            do {
                try self.tap.start(excludingPIDs: [getpid()], withMainSubDevice: self.useMainSubDevice)
            } catch {
                self.onSystemAudioFailed?("\(error)")
            }
        }
        rebuildWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for s in samples { sum += s * s }
        return (sum / Float(samples.count)).squareRoot()
    }
}
