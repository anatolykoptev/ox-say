import Foundation

/// The «Озвучка» section's sentences, resolved through L10nKey so every word
/// lives in Localizable.strings — the Studio menu's own strings stay English.
/// Each formatter takes the same inputs its English counterpart does plus a
/// `t` lookup: `L10nKey.text` in the app, the strings files in tests.
public enum SpeakText {
    /// The live line under the editor (ScriptLimit.statusLine's rules).
    public static func statusLine(editorText: String, _ t: (L10nKey) -> String) -> String {
        let text = ScriptLimit.script(from: editorText)
        let length = ScriptLimit.count(text)
        if length == 0 { return t(.speakStatusEmpty) }
        let over = ScriptLimit.overBy(text)
        if over > 0 {
            return String(format: t(.speakStatusOver), length, over, ScriptLimit.maxCharacters,
                          minutes(ScriptLimit.minutes(characters: ScriptLimit.maxCharacters), t))
        }
        return String(format: t(.speakStatusCount), length,
                      minutes(ScriptLimit.minutes(characters: length), t))
    }

    /// "1 minute" / "n minutes", one of the status line's moving parts.
    private static func minutes(_ count: Int, _ t: (L10nKey) -> String) -> String {
        count == 1 ? t(.speakMinutesOne) : String(format: t(.speakMinutesMany), count)
    }

    /// The running job's progress row (ProduceText.progressRow's rules):
    /// `«Title» — 3 of 10 parts`, or why it is not moving. `serviceWaiting`
    /// says the last poll got no answer, so the numbers may be old.
    public static func progressRow(_ job: ProduceJob, serviceWaiting: Bool, _ t: (L10nKey) -> String) -> String {
        let name = job.title.isEmpty ? t(.speakUntitled) : String(format: t(.speakProgressTitle), job.title)
        return "\(name) — \(serviceWaiting ? t(.speakProgressWaiting) : progressDetail(job, t))"
    }

    private static func progressDetail(_ job: ProduceJob, _ t: (L10nKey) -> String) -> String {
        switch job.status {
        case .pausedOnBattery: return t(.speakProgressPausedBattery)
        case .waitingForDictation: return t(.speakProgressPausedDictation)
        case .review: return "\(t(.speakProgressReady)) — \(listenText(job.partsToReview, t))"
        case .done: return t(.speakProgressReady)
        case .failed: return t(.speakProgressFailed)
        case .cancelled: return t(.speakProgressStopped)
        case .interrupted: return t(.speakProgressInterrupted)
        case .running, .unknown:
            return job.partsTotal > 0
                ? String(format: t(.speakProgressParts), job.partsDone, job.partsTotal)
                : t(.speakProgressStarting)
        }
    }

    private static func listenText(_ count: Int, _ t: (L10nKey) -> String) -> String {
        count == 1 ? t(.speakProgressListenOne) : String(format: t(.speakProgressListenMany), count)
    }

    /// The line for a job that ended (ProduceText.finishAlert's text); nil
    /// while it runs or was stopped on purpose. The daemon's own error text
    /// passes through verbatim behind a localized lead-in — it is the
    /// daemon's message, not this window's.
    public static func finishText(_ job: ProduceJob, _ t: (L10nKey) -> String) -> String? {
        switch job.status {
        case .done:
            let file = job.outputPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? t(.speakUntitled)
            return String(format: t(.speakFinishSaved), file)
        case .review:
            let file = job.outputPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? t(.speakUntitled)
            return job.partsToReview == 1
                ? String(format: t(.speakFinishReviewOne), file)
                : String(format: t(.speakFinishReviewMany), file, job.partsToReview)
        case .failed:
            return job.error.map { String(format: t(.speakServiceAnswered), $0) } ?? t(.speakFinishFailed)
        case .interrupted:
            return t(.speakFinishInterrupted)
        case .cancelled, .running, .waitingForDictation, .pausedOnBattery, .unknown:
            return nil
        }
    }

    /// Why the studio voice cannot run here (StudioMenu.unavailableText's rules):
    /// the daemon's reason in plain words, or the plain fallback for none or jargon.
    public static func unavailableText(reason: String?, _ t: (L10nKey) -> String) -> String {
        PlainWords.clean(reason ?? "", fallback: t(.speakCannotRun))
    }

    /// A daemon call's failure for the notice line (StudioError.message's
    /// rules): the known StudioError cases localized, a refusal's own message
    /// behind the lead-in, anything else the generic line.
    public static func notice(_ error: Error, _ t: (L10nKey) -> String) -> String {
        guard let studio = error as? StudioError else { return t(.speakErrorGeneric) }
        switch studio {
        case .daemonUnreachable: return t(.speakErrorNoService)
        case .timedOut: return t(.speakErrorTimeout)
        case .badResponse: return t(.speakErrorBadAnswer)
        case .refused(_, let message): return String(format: t(.speakServiceAnswered), message)
        }
    }

    /// A document read's failure (DocumentError.description's cases).
    public static func documentError(_ error: Error, _ t: (L10nKey) -> String) -> String {
        guard let document = error as? DocumentError else { return t(.speakDocOpenFailed) }
        switch document {
        case .unsupported(let ext) where ext.lowercased() == "pages": return t(.speakDocPages)
        case .unsupported: return t(.speakDocUnsupported)
        case .unreadable: return t(.speakDocUnreadable)
        case .passwordProtected: return t(.speakDocPassword)
        case .unknownEncoding: return t(.speakDocEncoding)
        }
    }

    /// Why an opened document gave no script (ReadDocument.emptyMessage's
    /// rules): text that was there and was all layout is not a scan, and is
    /// not said to be.
    public static func emptyMessage(of document: ReadDocument, _ t: (L10nKey) -> String) -> String {
        let hadText = document.pages.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let pdf = document.source == .pdf
        if hadText { return pdf ? t(.speakEmptyPDFCleaned) : t(.speakEmptyDocCleaned) }
        return pdf ? t(.speakEmptyPDF) : t(.speakEmptyDoc)
    }
}
