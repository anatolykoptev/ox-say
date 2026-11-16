import Foundation

/// `/status` `voice_clean`: whether this Mac can clean a file now, and if not, the daemon's stable reason.
public struct CleanStatus: Equatable {
    public var available: Bool
    /// `os_too_old`, `engine_missing`, `models_missing`; nil when available.
    public var reasonCode: String?
    /// The first cleanup is downloading the model.
    public var installing: Bool

    public init(available: Bool, reasonCode: String? = nil, installing: Bool = false) {
        self.available = available
        self.reasonCode = reasonCode
        self.installing = installing
    }

    static func decode(_ obj: [String: Any]?) -> CleanStatus? {
        guard let obj else { return nil }
        let code = (obj["reason_code"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return CleanStatus(available: obj["available"] as? Bool ?? false, reasonCode: code, installing: obj["installing"] as? Bool ?? false)
    }
}

/// The file being cleaned: its name and whether a cancel has been asked for and not yet landed.
public struct CleanWork: Equatable {
    public var name: String
    public var cancelling: Bool

    public init(name: String, cancelling: Bool = false) {
        self.name = name
        self.cancelling = cancelling
    }
}

/// A finished cleanup: the file that was picked and the file that was written, which play against each other.
public struct CleanDone: Equatable {
    public var inputPath: String
    public var outputPath: String
    public var video: Bool
    public var seconds: Double

    public init(inputPath: String, outputPath: String, video: Bool, seconds: Double) {
        self.inputPath = inputPath
        self.outputPath = outputPath
        self.video = video
        self.seconds = seconds
    }

    public var name: String { URL(fileURLWithPath: outputPath).lastPathComponent }

    /// The file a listener hears for a side of the comparison.
    public func url(for side: CleanSide) -> URL {
        URL(fileURLWithPath: side == .original ? inputPath : outputPath)
    }
}

/// What the cleanup bar on the Расшифровка page shows. One decision, so an unavailable cleaner can never offer a button and a
/// running job can never be hidden by a status read.
public enum CleanActionState: Equatable {
    /// This Mac cannot clean a file; the plain reason, and no button.
    case unavailable(reason: String)
    /// Ready. `firstUse`: the model is not on this Mac yet, so the first file downloads it before it is cleaned.
    case idle(firstUse: Bool)
    /// The first cleanup is downloading the model: no button until it has finished.
    case installing
    case working(name: String, cancelling: Bool)
    case done(CleanDone)
    case failed(String)

    /// A running job wins over everything (a status read in the middle of it must not hide it, nor offer a second file); a
    /// finished one stays until it is closed, whatever the status says afterwards, because its files are still there to play.
    /// A cleaner that cannot run beats an old failure: its reason is the better sentence and a button would only fail again.
    /// A missing model is not "unavailable": the first cleanup downloads it.
    public static func of(status: DaemonStatus?, working: CleanWork?, done: CleanDone?, error: String?,
                          text: (L10nKey) -> String = { $0.text }) -> CleanActionState {
        if let working { return .working(name: working.name, cancelling: working.cancelling) }
        if let done { return .done(done) }
        var firstUse = false
        if let status {
            guard let clean = status.voiceClean else { return .unavailable(reason: text(.cleanReasonUnknown)) }
            if !clean.available {
                switch clean.reasonCode {
                case "models_missing": firstUse = true
                case "os_too_old": return .unavailable(reason: text(.cleanReasonOSTooOld))
                case "engine_missing": return .unavailable(reason: text(.cleanReasonEngineMissing))
                default: return .unavailable(reason: text(.cleanReasonUnknown))
                }
                if clean.installing { return .installing }
            }
        }
        if let error { return .failed(error) }
        return .idle(firstUse: firstUse)
    }

    /// Whether the bar is on screen. It belongs to the file page and is hidden while that page has nothing to act on (the
    /// daemon is not answering, the list is still loading) unless there is a job or its outcome to show.
    public func isShown(on page: TranscribePageState) -> Bool {
        switch self {
        case .working, .done, .failed: return true
        case .idle, .unavailable, .installing:
            switch page {
            case .offline, .loading: return false
            case .empty, .list, .working: return true
            }
        }
    }
}
