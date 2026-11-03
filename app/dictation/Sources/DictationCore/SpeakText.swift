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
    /// `«Title» — 3 of 10 done`, or why it is not moving. `serviceWaiting`
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
    /// while it runs or was stopped on purpose. A done or review job still
    /// carrying an error is not a saved result: a loudness-only re-assembly
    /// that fails keeps the old status and reports why (the daemon's
    /// `outcome`), so the file stayed as it was and the line says the change
    /// did not happen.
    public static func finishText(_ job: ProduceJob, _ t: (L10nKey) -> String) -> String? {
        switch job.status {
        case .done:
            if job.error != nil { return failureText(job, t) }
            let file = job.outputPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? t(.speakUntitled)
            return String(format: t(.speakFinishSaved), file)
        case .review:
            if job.error != nil { return failureText(job, t) }
            let file = job.outputPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? t(.speakUntitled)
            return job.partsToReview == 1
                ? String(format: t(.speakFinishReviewOne), file)
                : String(format: t(.speakFinishReviewMany), file, job.partsToReview)
        case .failed:
            return failureText(job, t)
        case .interrupted:
            return t(.speakFinishInterrupted)
        case .cancelled, .running, .waitingForDictation, .pausedOnBattery, .unknown:
            return nil
        }
    }

    /// A failed delivery's line: the daemon's reason in plain words behind
    /// the lead-in, or the plain sentence when nothing readable is left — a
    /// jargon-only or empty error is never shown raw (PlainWords.clean's
    /// rules, the same the can't-run reason gets).
    private static func failureText(_ job: ProduceJob, _ t: (L10nKey) -> String) -> String {
        let reason = PlainWords.clean(job.error ?? "", fallback: "")
        return reason.isEmpty ? t(.speakFinishFailed) : String(format: t(.speakServiceAnswered), reason)
    }

    /// Why the studio voice cannot run here (StudioMenu.unavailableText's rules):
    /// the daemon's reason in plain words, or the plain fallback for none or jargon.
    public static func unavailableText(reason: String?, _ t: (L10nKey) -> String) -> String {
        PlainWords.clean(reason ?? "", fallback: t(.speakCannotRun))
    }

    /// A daemon call's failure for the notice line (StudioError.message's
    /// rules): the known StudioError cases localized, a refusal in its own
    /// words behind the lead-in, an empty message the status sentence exactly
    /// as `StudioError.message` words it — and anything else the generic line.
    public static func notice(_ error: Error, _ t: (L10nKey) -> String) -> String {
        guard let studio = error as? StudioError else { return t(.speakErrorGeneric) }
        switch studio {
        case .daemonUnreachable: return t(.speakErrorNoService)
        case .timedOut: return t(.speakErrorTimeout)
        case .badResponse: return t(.speakErrorBadAnswer)
        case .refused(_, let message):
            return message.isEmpty ? studio.message(text: t) : String(format: t(.speakServiceAnswered), message)
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
