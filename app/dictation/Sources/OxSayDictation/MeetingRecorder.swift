import AVFoundation
import CoreAudio
import DictationCore
import os

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
    enum StartError: UserFacingError, CustomStringConvertible {
        /// The sentence is already in the user's language (the permission texts).
        case microphone(String)
        var description: String {
            switch self {
            case .microphone(let why): return why
            }
        }
        var userText: String { description }
    }

    /// What a finished recording did with the clock: logged by the controller as numbers, never as content.
    struct Summary {
        var meDropped = 0, mePadded = 0, themDropped = 0, themPadded = 0
        var micConversions: (failed: Int, empty: Int) = (0, 0)
        var tapConversions: (failed: Int, empty: Int) = (0, 0)
        var tapNilBuffers = 0
        var tapExclusionMissing = 0
        var failedWrites = 0
    }

    /// The other side counts as active while its last loud chunk is this recent.
    private static let activeWindow: TimeInterval = 3
    private static let loudRMS: Float = 0.003

    /// Called on the main thread when the system audio could not be (re)started: once per streak of failures. It carries
    /// no reason: the framework's error is English and goes to the log, the app says the loss in the user's language.
    /// The recorder goes on retrying (`Reacquire`) for as long as the recording runs.
    var onSystemAudioFailed: (() -> Void)?
    /// ...and when a later attempt worked.
    var onSystemAudioRecovered: (() -> Void)?
    /// The same two for the microphone after a route change.
    var onMicrophoneFailed: (() -> Void)?
    var onMicrophoneRecovered: (() -> Void)?

    private let mic = AVAudioEngine()
    private let micConverter = PCM16kConverter()
    private let tap = SystemAudioTap()
    private var me: PcmChannelWriter?
    private var them: PcmChannelWriter?
    /// Guards `me` and `them`: the audio threads append under it and `stop` nils them under it, so a buffer that is
    /// still in flight never meets a closed file or a half-assigned reference.
    private let writersLock = NSLock()
    private var tapRetry = Reacquire()
    /// The microphone's restart chain; one per recording (`begin` in `start`, `cancel` in `stop`), so a timer left from
    /// an earlier recording cannot restart the engine next to the new one (#266).
    private lazy var micChain = RetryChain(
        attempt: { [weak self] in try self?.startMicrophone() },
        schedule: { delay, work in DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work) },
        onFailed: { [weak self] error in
            self?.log.error("microphone: restart failed: \(String(describing: error), privacy: .public)")
            self?.onMicrophoneFailed?()
        },
        onRecovered: { [weak self] in self?.onMicrophoneRecovered?() })
    private let log = Logger(subsystem: "io.github.anatolykoptev.ox-say.dictation", category: "meeting")
    private var rateListener: (device: AudioObjectID, block: AudioObjectPropertyListenerBlock)?
    private var outputListener: AudioObjectPropertyListenerBlock?
    private var rebuildWork: DispatchWorkItem?
    private let lock = NSLock()
    private var meLevel: Float = 0
    private var themLevel: Float = 0
    private var themLoudAt = Date.distantPast
    private var themEverLoud = false
    private var tapCallbacks = 0
    /// When the tap last delivered a buffer: `DispatchTime.uptimeNanoseconds`, monotonic, so a clock step cannot skew
    /// the silent-tap judgement (`TapLoss.silence`).
    private var tapLastNanos: UInt64?
    /// Moved on by `start` and `stop`: a tap start's answer that arrives after its recording is dropped (#266).
    private var tapGeneration = Generation()
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
    var writeFailed: Bool { writersLock.withLock { (me?.failedWrites ?? 0) > 0 || (them?.failedWrites ?? 0) > 0 } }
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
        let meWriter = try PcmChannelWriter(url: dir.appendingPathComponent("me.pcm"), t0: t0)
        let themWriter: PcmChannelWriter
        do {
            themWriter = try PcmChannelWriter(url: dir.appendingPathComponent("them.pcm"), t0: t0)
        } catch {
            meWriter.finish(atNanos: t0)
            throw error
        }
        writersLock.withLock {
            me = meWriter
            them = themWriter
        }
        tapRetry = Reacquire()
        micChain.begin()
        lock.withLock {
            meLevel = 0; themLevel = 0; themLoudAt = .distantPast; themEverLoud = false; tapCallbacks = 0; tapPeak = 0
            tapLastNanos = nil
        }
        tapGeneration.advance()

        do {
            try startMicrophone()
        } catch {
            // Neither writer may stay open on a recording that never began.
            writersLock.withLock {
                me?.finish(atNanos: t0)
                them?.finish(atNanos: t0)
                me = nil
                them = nil
            }
            throw error
        }
        // AirPods connecting or a new default input stops the engine; without this
        // the microphone channel would go silent for the rest of the call.
        micObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: mic, queue: .main) { [weak self] _ in
            guard let self, self.started != nil else { return }
            self.mic.stop()
            self.restartMicrophone()
        }

        tap.onSamples = { [weak self] samples, nanos in
            guard let self else { return }
            self.writersLock.withLock { self.them?.append(samples, atNanos: nanos) }
            let level = Self.rms(samples)
            let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
            self.lock.withLock {
                self.themLevel = level
                self.tapCallbacks += 1
                self.tapLastNanos = DispatchTime.now().uptimeNanoseconds
                self.tapPeak = max(self.tapPeak, peak)
                if level > Self.loudRMS {
                    self.themLoudAt = Date()
                    self.themEverLoud = true
                }
            }
        }
        started = Date()
        // The microphone alone is still a recording: a tap that cannot start is told and retried (`tapStarted`).
        startTap()
        watchOutputDevice()
    }

    private func startMicrophone() throws {
        let input = mic.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw StartError.microphone(L10nKey.meetingMicNone.text) }
        // The one engine lives for the whole recording; a tap left on bus 0 (a start that failed, a restart) would make
        // the next installTap raise an exception nothing can catch.
        try EngineStart.start(removeTap: { input.removeTap(onBus: 0) }, installTap: {
            input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, when in
                guard let self, let samples = self.micConverter.convert(buffer) else { return }
                let ticks = when.isHostTimeValid ? when.hostTime : AudioGetCurrentHostTime()
                self.writersLock.withLock { self.me?.append(samples, atNanos: HostClock.nanos(fromHostTicks: ticks)) }
                self.lock.withLock { self.meLevel = Self.rms(samples) }
            }
        }, start: {
            mic.prepare()
            try mic.start()
        })
    }

    /// After a route change: start the microphone again, and keep trying (0.4, 1, 2, 4, then every 5 s) while the
    /// recording runs. The user hears about the first failure of a streak and about the recovery.
    private func restartMicrophone() {
        guard started != nil else { return }
        micChain.run()
    }

    /// Stops both sources, pads both files to the same length and closes them. The numbers go back to the caller.
    @discardableResult
    func stop() -> Summary {
        if let micObserver { NotificationCenter.default.removeObserver(micObserver) }
        micObserver = nil
        micChain.cancel()
        tapGeneration.advance()
        unwatchOutputDevice()
        mic.inputNode.removeTap(onBus: 0)
        mic.stop()
        tap.stop()
        let end = HostClock.nanos(fromHostTicks: AudioGetCurrentHostTime())
        var summary = Summary()
        // Under the lock the audio threads append with: a buffer still in flight finishes before the files close.
        writersLock.withLock {
            me?.finish(atNanos: end)
            them?.finish(atNanos: end)
            summary.meDropped = me?.droppedSamples ?? 0
            summary.mePadded = me?.paddedSamples ?? 0
            summary.themDropped = them?.droppedSamples ?? 0
            summary.themPadded = them?.paddedSamples ?? 0
            summary.failedWrites = (me?.failedWrites ?? 0) + (them?.failedWrites ?? 0)
            me = nil
            them = nil
        }
        summary.micConversions = (micConverter.failedConversions, micConverter.emptyConversions)
        let tapCounters = tap.counters
        summary.tapConversions = (tapCounters.failed, tapCounters.empty)
        summary.tapNilBuffers = tapCounters.nilBuffers
        summary.tapExclusionMissing = tapCounters.exclusionMissing
        started = nil
        return summary
    }

    /// Whether the call is heard through speakers (decided once, when the meeting starts).
    static func echoRisk() -> Bool {
        guard let route = CoreAudioProps.outputRoute() else { return true }
        return OutputRoute.isLikelySpeakers(transport: route.transport, dataSource: route.dataSource, name: route.name)
    }

    // The tap is bound to the output device it started on; AirPods connecting mid-call would leave it silent, so a
    // change of the default output rebuilds it. The same when the default device changes its sample rate in place
    // (a call app switching it), which the tap's own format does not follow. The gap is padded with silence by the
    // channel writer.
    private func watchOutputDevice() {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.watchSampleRate()
                self?.scheduleTapRebuild(after: 0.4)
            }
        }
        outputListener = block
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block)
        watchSampleRate()
    }

    /// Listens for a sample-rate change on the current default output device (moved to the new device when it changes).
    private func watchSampleRate() {
        unwatchSampleRate()
        guard let device = CoreAudioProps.defaultOutputDevice() else { return }
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async { self?.scheduleTapRebuild(after: 0.4) }
        }
        rateListener = (device, block)
        AudioObjectAddPropertyListenerBlock(device, &address, DispatchQueue.main, block)
    }

    private func unwatchSampleRate() {
        guard let (device, block) = rateListener else { return }
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectRemovePropertyListenerBlock(device, &address, DispatchQueue.main, block)
        rateListener = nil
    }

    private func unwatchOutputDevice() {
        rebuildWork?.cancel()
        unwatchSampleRate()
        guard let block = outputListener else { return }
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block)
        outputListener = nil
    }

    /// Builds the tap again after `delay`. A failure schedules the next attempt (`Reacquire`), a success ends the streak.
    private func scheduleTapRebuild(after delay: TimeInterval) {
        rebuildWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.started != nil else { return }
            self.startTap()
        }
        rebuildWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Starts or rebuilds the tap off the main thread; the answer comes back to `tapStarted` on main.
    private func startTap() {
        let token = tapGeneration.value
        tap.start(excludingPIDs: [getpid()], withMainSubDevice: useMainSubDevice) { [weak self] outcome in
            self?.tapStarted(outcome, token: token)
        }
    }

    private func tapStarted(_ outcome: SystemAudioTap.StartOutcome, token: Int) {
        // An answer for a recording that is over (a start blocked on a permission prompt, then stop, then a new start)
        // must not post a loss or burn the retry streak of the one running now.
        guard started != nil, tapGeneration.isCurrent(token) else { return }
        switch outcome {
        case .started: if tapRetry.succeeded() { onSystemAudioRecovered?() }
        case .stopped: break
        case .failed(let error): tapFailed(error)
        }
    }

    private func tapFailed(_ error: Error) {
        guard started != nil else { return }
        log.error("system audio tap: failed: \(String(describing: error), privacy: .public)")
        // A rebuild that failed while the old tap still DELIVERS loses nothing: retried and logged, not announced. Once
        // the old tap goes quiet, or enough rebuilds failed, the loss is told (`TapLoss`).
        let silence = lock.withLock { TapLoss.silence(lastNanos: tapLastNanos, nowNanos: DispatchTime.now().uptimeNanoseconds) }
        let lost = TapLoss.isLost(hasTap: tap.isRunning, sinceLastBuffer: silence, consecutiveFailures: tapRetry.failures + 1)
        if !lost { log.error("system audio tap: rebuild failed, the previous tap keeps delivering") }
        let step = tapRetry.failed(sourceLost: lost)
        if step.notify { onSystemAudioFailed?() }
        scheduleTapRebuild(after: step.delay)
    }

    private static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for s in samples { sum += s * s }
        return (sum / Float(samples.count)).squareRoot()
    }
}
