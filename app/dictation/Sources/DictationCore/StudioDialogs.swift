import Foundation

/// The words of the Studio voiceover flow's alerts, in the user's language: `text` resolves a key (the bundle's by
/// default, the shipped strings in tests). The daemon's own words (a refusal, a failed job's reason) pass through as sent.
public enum StudioDialogs {
    public typealias Text = (L10nKey) -> String

    /// The finished voiceover's file could not be opened to play it.
    public static func playFailed(text: Text = { $0.text }) -> UpdateDialog {
        UpdateDialog(title: text(.studioPlayFailedTitle), text: text(.studioPlayFailedText), buttons: [text(.commonOk)])
    }

    /// The voice list could not be read: the service is not answering.
    public static func serviceDown(text: Text = { $0.text }) -> UpdateDialog {
        UpdateDialog(title: text(.studioServiceDownTitle), text: text(.studioServiceDownText), buttons: [text(.commonOk)])
    }

    /// The daemon refused to start the voiceover; the review window reopens with the person's text.
    public static func startFailed(_ error: Error, text: Text = { $0.text }) -> UpdateDialog {
        UpdateDialog(title: text(.studioStartFailedTitle), text: "\(StudioError.plain(error, text: text)) \(text(.studioStartFailedKept))",
                     buttons: [text(.commonOk)])
    }

    /// The document gave no text to read.
    public static func nothingToRead(_ read: ReadScript, text: Text = { $0.text }) -> UpdateDialog {
        UpdateDialog(title: text(.studioNothingTitle), text: read.emptyMessage(text: text), buttons: [text(.commonOk)])
    }

    /// The document could not be read at all.
    public static func readFailed(_ error: Error, text: Text = { $0.text }) -> UpdateDialog {
        UpdateDialog(title: text(.studioReadFailedTitle), text: (error as? DocumentError)?.message(text: text) ?? text(.studioOpenFailed),
                     buttons: [text(.commonOk)])
    }

    /// Stop a running voiceover: the first button stops it.
    public static func stop(text: Text = { $0.text }) -> UpdateDialog {
        UpdateDialog(title: text(.studioStopTitle), text: text(.studioStopText),
                     buttons: [text(.studioStopVoiceover), text(.studioKeepGoing)])
    }

    public static func stopFailed(_ error: Error, text: Text = { $0.text }) -> UpdateDialog {
        UpdateDialog(title: text(.studioStopFailedTitle), text: StudioError.plain(error, text: text), buttons: [text(.commonOk)])
    }

    public static func continueFailed(_ error: Error, text: Text = { $0.text }) -> UpdateDialog {
        UpdateDialog(title: text(.studioContinueFailedTitle), text: StudioError.plain(error, text: text), buttons: [text(.commonOk)])
    }

    /// A voiceover that ended: Show in Finder / Play / OK when there is a file, OK alone otherwise; nil for one stopped on purpose.
    public static func finished(_ job: ProduceJob, text: Text = { $0.text }) -> UpdateDialog? {
        guard let (title, body) = ProduceText.finishAlert(job, text: text) else { return nil }
        let buttons = job.outputPath == nil ? [text(.commonOk)]
                                            : [text(.studioFinishShow), text(.studioFinishPlay), text(.commonOk)]
        return UpdateDialog(title: title, text: body, buttons: buttons)
    }
}
