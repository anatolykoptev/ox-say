import Foundation

/// The «Ролик» window's sentences, resolved through L10nKey so every word
/// lives in Localizable.strings — the Studio menu's own strings stay English.
/// Each formatter takes the same inputs its English counterpart does plus a
/// `t` lookup: `L10nKey.text` in the app, the strings files in tests.
public enum ReelText {
    /// The live line under the editor (ScriptLimit.statusLine's rules).
    public static func statusLine(editorText: String, _ t: (L10nKey) -> String) -> String {
        let text = ScriptLimit.script(from: editorText)
        let length = ScriptLimit.count(text)
        if length == 0 { return t(.reelStatusEmpty) }
        let over = ScriptLimit.overBy(text)
        if over > 0 {
            return String(format: t(.reelStatusOver), length, over, ScriptLimit.maxCharacters,
                          minutes(ScriptLimit.minutes(characters: ScriptLimit.maxCharacters), t))
        }
        return String(format: t(.reelStatusCount), length,
                      minutes(ScriptLimit.minutes(characters: length), t))
    }

    /// "1 minute" / "n minutes", one of the status line's moving parts.
    private static func minutes(_ count: Int, _ t: (L10nKey) -> String) -> String {
        count == 1 ? t(.reelMinutesOne) : String(format: t(.reelMinutesMany), count)
    }

    /// The running job's progress row (ProduceText.progressRow's rules):
    /// `«Title» — 3 of 10 parts`, or why it is not moving. `serviceWaiting`
    /// says the last poll got no answer, so the numbers may be old.
    public static func progressRow(_ job: ProduceJob, serviceWaiting: Bool, _ t: (L10nKey) -> String) -> String {
        let name = job.title.isEmpty ? t(.reelUntitled) : String(format: t(.reelProgressTitle), job.title)
        return "\(name) — \(serviceWaiting ? t(.reelProgressWaiting) : progressDetail(job, t))"
    }

    private static func progressDetail(_ job: ProduceJob, _ t: (L10nKey) -> String) -> String {
        switch job.status {
        case .pausedOnBattery: return t(.reelProgressPausedBattery)
        case .waitingForDictation: return t(.reelProgressPausedDictation)
        case .review: return "\(t(.reelProgressReady)) — \(listenText(job.partsToReview, t))"
        case .done: return t(.reelProgressReady)
        case .failed: return t(.reelProgressFailed)
        case .cancelled: return t(.reelProgressStopped)
        case .interrupted: return t(.reelProgressInterrupted)
        case .running, .unknown:
            return job.partsTotal > 0
                ? String(format: t(.reelProgressParts), job.partsDone, job.partsTotal)
                : t(.reelProgressStarting)
        }
    }

    private static func listenText(_ count: Int, _ t: (L10nKey) -> String) -> String {
        count == 1 ? t(.reelProgressListenOne) : String(format: t(.reelProgressListenMany), count)
    }

    /// The line for a job that ended (ProduceText.finishAlert's text); nil
    /// while it runs or was stopped on purpose. The daemon's own error text
    /// passes through verbatim behind a localized lead-in — it is the
    /// daemon's message, not this window's.
    public static func finishText(_ job: ProduceJob, _ t: (L10nKey) -> String) -> String? {
        switch job.status {
        case .done:
            let file = job.outputPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? t(.reelUntitled)
            return String(format: t(.reelFinishSaved), file)
        case .review:
            let file = job.outputPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? t(.reelUntitled)
            return job.partsToReview == 1
                ? String(format: t(.reelFinishReviewOne), file)
                : String(format: t(.reelFinishReviewMany), file, job.partsToReview)
        case .failed:
            return job.error.map { String(format: t(.reelServiceAnswered), $0) } ?? t(.reelFinishFailed)
        case .interrupted:
            return t(.reelFinishInterrupted)
        case .cancelled, .running, .waitingForDictation, .pausedOnBattery, .unknown:
            return nil
        }
    }

    /// Why the studio voice cannot run here (StudioMenu.unavailableText's rules):
    /// the daemon's reason in plain words, or the plain fallback for none or jargon.
    public static func unavailableText(reason: String?, _ t: (L10nKey) -> String) -> String {
        PlainWords.clean(reason ?? "", fallback: t(.reelCannotRun))
    }

    /// A daemon call's failure for the notice line (StudioController.plain's
    /// rules): the known StudioError cases localized, a refusal's own message
    /// behind the lead-in, anything else the generic line.
    public static func notice(_ error: Error, _ t: (L10nKey) -> String) -> String {
        guard let studio = error as? StudioError else { return t(.reelErrorGeneric) }
        switch studio {
        case .daemonUnreachable: return t(.reelErrorNoService)
        case .timedOut: return t(.reelErrorTimeout)
        case .badResponse: return t(.reelErrorBadAnswer)
        case .refused(_, let message): return String(format: t(.reelServiceAnswered), message)
        }
    }

    /// A document read's failure (DocumentError.description's cases).
    public static func documentError(_ error: Error, _ t: (L10nKey) -> String) -> String {
        guard let document = error as? DocumentError else { return t(.reelDocOpenFailed) }
        switch document {
        case .unsupported(let ext) where ext.lowercased() == "pages": return t(.reelDocPages)
        case .unsupported: return t(.reelDocUnsupported)
        case .unreadable: return t(.reelDocUnreadable)
        case .passwordProtected: return t(.reelDocPassword)
        case .unknownEncoding: return t(.reelDocEncoding)
        }
    }

    /// Why an opened document gave no script (ReadDocument.emptyMessage's
    /// rules): text that was there and was all layout is not a scan, and is
    /// not said to be.
    public static func emptyMessage(of document: ReadDocument, _ t: (L10nKey) -> String) -> String {
        let hadText = document.pages.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let pdf = document.source == .pdf
        if hadText { return pdf ? t(.reelEmptyPDFCleaned) : t(.reelEmptyDocCleaned) }
        return pdf ? t(.reelEmptyPDF) : t(.reelEmptyDoc)
    }
}
