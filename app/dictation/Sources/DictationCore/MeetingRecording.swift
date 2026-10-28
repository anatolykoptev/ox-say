import Foundation

/// Decides whether the system-audio tap works, from what the recorder measured. The tap can look authorized
/// and still deliver only zeros until the user switches the permission off and on (P0a, 2026-10-26, macOS 26.5.1):
/// its callbacks fire, every sample is 0.0, and another process is playing. The recorder reports numbers; this
/// says what they mean, and the controller tells the user once per verdict.
public enum SystemAudioGuard {
    public struct Sample: Equatable {
        /// Tap callbacks since the recording began.
        public var callbacks: Int
        /// The largest absolute sample the tap has delivered so far.
        public var peak: Float
        public var elapsed: TimeInterval
        /// How long another process has been playing audio without a break; 0 when none is.
        public var playingFor: TimeInterval
        /// The other side was audible at least once.
        public var heardLoud: Bool
        /// How long the microphone channel has been loud in total: somebody on this side is talking.
        public var micLoudFor: TimeInterval

        public init(callbacks: Int, peak: Float, elapsed: TimeInterval, playingFor: TimeInterval, heardLoud: Bool,
                    micLoudFor: TimeInterval = 0) {
            self.micLoudFor = micLoudFor
            self.callbacks = callbacks
            self.peak = peak
            self.elapsed = elapsed
            self.playingFor = playingFor
            self.heardLoud = heardLoud
        }
    }

    public enum Verdict: Equatable {
        /// Nothing to say (yet).
        case waiting
        /// The other side was heard.
        case fine
        /// Callbacks arrive, every sample is zero and something plays: the permission needs a switch off and on.
        case silentTap
        /// The tap never delivered a buffer.
        case noCallbacks
        /// Samples arrive but the other side has not been audible for `quietAfter`.
        case otherSideQuiet
    }

    /// The tap gets this long to start delivering before anything is said.
    public static let settle: TimeInterval = 5
    /// A call app plays digital silence until the other side joins, and auto-start begins 4 s after the microphone
    /// opens, so zeros mean a broken permission only after a process has played this long without a sample...
    public static let playingBeforeVerdict: TimeInterval = 20
    /// ...or when somebody on this side has been talking this long (cumulative) while something plays: a person speaks
    /// to a person who is there, so a healthy call has produced far-side samples by now.
    public static let micLoudBeforeVerdict: TimeInterval = 10
    /// The "something plays" part of the microphone rule.
    public static let playingWithMic: TimeInterval = 5
    /// The old rule: nobody audible on the other side for this long into a recording.
    public static let quietAfter: TimeInterval = 20

    /// System Settings → Privacy & Security → Screen & System Audio Recording.
    public static let settingsURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"

    public static func assess(_ s: Sample) -> Verdict {
        if s.heardLoud { return .fine }
        guard s.elapsed >= settle else { return .waiting }
        if s.callbacks == 0 { return .noCallbacks }
        if s.peak == 0, s.playingFor >= playingBeforeVerdict
            || (s.playingFor >= playingWithMic && s.micLoudFor >= micLoudBeforeVerdict) { return .silentTap }
        if s.elapsed >= quietAfter { return .otherSideQuiet }
        return .waiting
    }
}

/// Limits the app keeps to what the daemon accepts and can use.
public enum MeetingLimits {
    /// The daemon separates the far side's voices only up to two hours of audio (internal/daemon/diarize.go,
    /// `diarMaxSeconds`): ox-diar holds the whole channel in memory (about 1.06 GB per hour), and a longer call keeps one
    /// far-side label. The recording stops a minute short of it, so the stop's own lag (one badge tick, the finish
    /// call) cannot tip the channel over. Disk is not the limit: both channels together are about 230 MB an hour.
    /// `MeetingLimitsTests` reads the Go constant, so the two cannot drift apart.
    public static let maxRecordingSeconds: TimeInterval = 2 * 3600 - 60

    public static func reachedCap(elapsed: TimeInterval) -> Bool { elapsed >= maxRecordingSeconds }

    /// The daemon's caps (internal/daemon/meetings_http.go), counted in runes after trimming.
    public static let titleMax = 200
    public static let labelMax = 80
    public static let sourceMax = 40

    /// `text` trimmed and cut to `limit` Unicode scalars (the daemon counts runes).
    public static func clamp(_ text: String, to limit: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.unicodeScalars.count > limit else { return trimmed }
        var out = String.UnicodeScalarView()
        out.append(contentsOf: trimmed.unicodeScalars.prefix(limit))
        return String(out).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The meeting's working title for a call source, "" for a manual recording (the daemon then names it by date).
    public static func title(forSource source: String) -> String {
        switch source {
        case "", "manual": return ""
        case "oxpulse": return "OxPulse call"
        case "whatsapp": return "WhatsApp call"
        default: return source.capitalized + " call"
        }
    }
}

/// Copies a finished meeting into the notes folder and keeps the ledger of what it wrote (path, hashes, stale flag),
/// deciding from that ledger whether to write a new copy, refresh the old one or leave the user's alone.
public struct MeetingExporter {
    public enum Outcome: Equatable {
        /// A new copy was written.
        case written(URL)
        /// The earlier copy was rewritten with the current texts.
        case refreshed(URL)
        /// The copy is the user's now (they edited it, or it predates the ledger and has no hashes): left as it is.
        case keptEdited(URL?)
        case alreadyExported
        /// Nothing was written; `reason` is in plain words.
        case failed(String)

        /// What the user must be told, nil when nothing.
        public var noticeKey: L10nKey? {
            switch self {
            case .keptEdited: return .noticeMeetingCopyKept
            case .failed: return .noticeMeetingFailed
            case .written, .refreshed, .alreadyExported: return nil
            }
        }
    }

    private let defaults: UserDefaults
    private let fm: FileManager
    private let stage: (Data, URL) throws -> Void
    private let replace: ((URL, URL) throws -> Void)?

    /// `stage` writes one staged text during a refresh and `replace` moves it into place; tests make them fail.
    public init(defaults: UserDefaults, fm: FileManager = .default,
                stage: @escaping (Data, URL) throws -> Void = { try $0.write(to: $1) },
                replace: ((URL, URL) throws -> Void)? = nil) {
        self.defaults = defaults
        self.fm = fm
        self.stage = stage
        self.replace = replace
    }

    public func export(_ info: MeetingInfo) -> Outcome {
        let copied = MeetingSettings.exported(defaults).contains(info.id)
        // A text this meeting has now and the copy lacks (notes that arrived after a transcript-only copy) is as good
        // as a stale flag: the copy is brought up to date, in place.
        let ledger = MeetingSettings.exportHashes(info.id, defaults)
        let missingText = copied && MeetingSettings.exportPath(info.id, defaults) != nil
            && ((info.notesMD != nil && ledger["notes.md"] == nil) || (info.transcriptMD != nil && ledger["transcript.md"] == nil))
        let stale = MeetingSettings.exportStale(defaults).contains(info.id) || missingText
        if stale {
            if let path = MeetingSettings.exportPath(info.id, defaults) {
                let dir = URL(fileURLWithPath: path, isDirectory: true)
                do {
                    switch try NotesExport.refresh(info: info, at: dir, expected: MeetingSettings.exportHashes(info.id, defaults), fm: fm, stage: stage, replace: replace) {
                    case .refreshed:
                        // Merge: a text this meeting does not have yet (notes still pending) keeps its stored hash.
                        let merged = MeetingSettings.exportHashes(info.id, defaults).merging(NotesExport.hashes(of: info)) { _, new in new }
                        MeetingSettings.setExportHashes(info.id, merged, defaults)
                        MeetingSettings.setExportStale(info.id, false, defaults)
                        return .refreshed(dir)
                    case .keptEdited:
                        return .keptEdited(dir)
                    }
                } catch let partial as NotesExport.PartialRefresh {
                    // Some texts are new already: they are ours, so the next refresh does not take them for an edit.
                    let merged = MeetingSettings.exportHashes(info.id, defaults).merging(partial.replaced) { _, new in new }
                    MeetingSettings.setExportHashes(info.id, merged, defaults)
                    return .failed(NotesExport.explain(partial.underlying))
                } catch NotesExport.ExportError.folderMoved {
                    // The folder was moved or deleted: a new copy below.
                } catch {
                    // Anything else (a staging write) is a failure, not a reason for a second copy.
                    return .failed(NotesExport.explain(error))
                }
            } else if copied {
                // Copied before the ledger existed: no path, no hashes. It is the user's; no duplicate beside it.
                return .keptEdited(nil)
            }
        } else if copied {
            return .alreadyExported
        }
        do {
            let dir = try NotesExport.write(info: info, in: MeetingSettings.folder(defaults), fm: fm)
            MeetingSettings.markExported(info.id, defaults)
            MeetingSettings.setExportPath(info.id, dir.path, defaults)
            MeetingSettings.setExportHashes(info.id, NotesExport.hashes(of: info), defaults)
            MeetingSettings.setExportStale(info.id, false, defaults)
            return .written(dir)
        } catch {
            return .failed(NotesExport.explain(error))
        }
    }
}
